require 'thread'

module Redwood

class PollManager
  include Singleton

  HookManager.register "before-add-message", <<EOS
Executes immediately before a message is added to the index.
Variables:
  message: the new message
EOS

  HookManager.register "before-poll", <<EOS
Executes immediately before a poll for new messages commences.
No variables.
EOS

  HookManager.register "after-poll", <<EOS
Executes immediately after a poll for new messages completes.
Variables:
                   num: the total number of new messages added in this poll
             num_inbox: the number of new messages added in this poll which
                        appear in the inbox (i.e. were not auto-archived).
num_inbox_total_unread: the total number of unread messages in the inbox
         from_and_subj: an array of (from email address, subject) pairs
   from_and_subj_inbox: an array of (from email address, subject) pairs for
                        only those messages appearing in the inbox
EOS

  DELAY = $config[:poll_interval] || 300

  def initialize
    @mutex = Mutex.new
    @thread = nil
    @last_poll = nil
    @polling = false
    @poll_sources = nil
    @mode = nil
    @should_clear_running_totals = false
    clear_running_totals # defines @running_totals
    UpdateManager.register self
  end

  def poll_with_sources
    @mode ||= PollMode.new
    HookManager.run "before-poll"

    BufferManager.flash "Polling for new messages..."
    num, numi, from_and_subj, from_and_subj_inbox, loaded_labels = @mode.poll
    clear_running_totals if @should_clear_running_totals
    @running_totals[:num] += num
    @running_totals[:numi] += numi
    @running_totals[:loaded_labels] += loaded_labels || []
    if @running_totals[:num] > 0
      BufferManager.flash "Loaded #{@running_totals[:num].pluralize 'new message'}, #{@running_totals[:numi]} to inbox. Labels: #{@running_totals[:loaded_labels].map{|l| l.to_s}.join(', ')}"
    else
      BufferManager.flash "No new messages." 
    end

    HookManager.run "after-poll", :num => num, :num_inbox => numi, :from_and_subj => from_and_subj, :from_and_subj_inbox => from_and_subj_inbox, :num_inbox_total_unread => lambda { Index.num_results_for :labels => [:inbox, :unread] }

  end

  def poll
    return if @polling
    @polling = true
    @poll_sources = SourceManager.usual_sources
    num, numi = poll_with_sources
    @polling = false
    [num, numi]
  end

  def poll_unusual
    return if @polling
    @polling = true
    @poll_sources = SourceManager.unusual_sources
    num, numi = poll_with_sources
    @polling = false
    [num, numi]
  end

  def start
    @thread = Redwood::reporting_thread("periodic poll") do
      while true
        sleep DELAY / 2
        poll if @last_poll.nil? || (Time.now - @last_poll) >= DELAY
      end
    end
  end

  def stop
    @thread.kill if @thread
    @thread = nil
  end

  def do_poll
    total_num = total_numi = 0
    from_and_subj = []
    from_and_subj_inbox = []
    loaded_labels = Set.new

    @mutex.synchronize do
      @poll_sources.each do |source|
        begin
          yield "Loading from #{source}... " unless source.has_errors?
        rescue SourceError => e
          warn "problem getting messages from #{source}: #{e.message}"
          Redwood::report_broken_sources :force_to_top => true
          next
        end

        num = 0
        numi = 0
        poll_from source do |action,m,old_m|
          if action == :delete
            yield "Deleting #{m.id}"
          else
          if old_m
            if not old_m.locations.member? [source, m.source_info]
              yield "Message at #{m.source_info} is an updated of an old message. Updating labels from #{old_m.labels.to_a * ','} => #{m.labels.to_a * ','}"
            else
              yield "Skipping already-imported message at #{m.source_info}"
            end
          else
            yield "Found new message at #{m.source_info} with labels #{m.labels.to_a * ','}"
            loaded_labels.merge m.labels
            num += 1
            from_and_subj << [m.from && m.from.longname, m.subj]
            if (m.labels & [:inbox, :spam, :deleted, :killed]) == Set.new([:inbox])
              from_and_subj_inbox << [m.from && m.from.longname, m.subj]
              numi += 1
            end
          end
          end
        end
        yield "Found #{num} messages, #{numi} to inbox." unless num == 0
        total_num += num
        total_numi += numi
      end

      loaded_labels = loaded_labels - LabelManager::HIDDEN_RESERVED_LABELS - [:inbox, :killed]
      yield "Done polling; loaded #{total_num} new messages total"
      @last_poll = Time.now
      @polling = false
    end
    [total_num, total_numi, from_and_subj, from_and_subj_inbox, loaded_labels]
  end

  ## like Source#poll, but yields successive Message objects, which have their
  ## labels and locations set correctly. The Messages are saved to or removed
  ## from the index after being yielded.
  def poll_from source, opts={}
    begin
      return if source.has_errors?

      source.poll do |sym, args|
        if source.has_errors?
          warn "error loading messages from #{source}: #{source.error.message}"
          return
        end

        case sym
        when :add
          m = Message.build_from_source source, args[:info]
          old_m = Index.build_message m.id
          m.labels += args[:labels]
          m.labels.delete :unread if source.read?
          m.labels.delete :unread if m.source_marked_read? # preserve read status if possible
          m.labels.each { |l| LabelManager << l }
          m.labels = old_m.labels + (m.labels - [:unread, :inbox]) if old_m
          m.locations = old_m.locations + m.locations if old_m
          HookManager.run "before-add-message", :message => m
          yield :add, m, old_m if block_given?
          Index.sync_message m, true
          UpdateManager.relay self, :added, m
        when :delete
          Index.each_message :location => [source.id, args[:info]] do |m|
            m.locations.delete [source,args[:info]]
            yield :delete, m, [source,args[:info]] if block_given?
            Index.sync_message m, false
            UpdateManager.relay self, :deleted, m
          end
        end
      end
    rescue SourceError => e
      warn "problem getting messages from #{source}: #{e.message}"
      Redwood::report_broken_sources :force_to_top => true
    end
  end

  def add_new_messages source, add_labels, remove_labels
    each_message_from(source) do |action,m|
      next unless action == :add
      remove_labels.each { |l| m.remove_label l }
      add_labels.each { |l| m.add_label l }
      add_new_message m
    end
  end

  def handle_idle_update sender, idle_since; @should_clear_running_totals = false; end
  def handle_unidle_update sender, idle_since; @should_clear_running_totals = true; clear_running_totals; end
  def clear_running_totals; @running_totals = {:num => 0, :numi => 0, :loaded_labels => Set.new}; end
end

end
