class MiqTask < ApplicationRecord
  serialize :context_data
  STATE_INITIALIZED = 'Initialized'.freeze
  STATE_QUEUED      = 'Queued'.freeze
  STATE_ACTIVE      = 'Active'.freeze
  STATE_FINISHED    = 'Finished'.freeze

  STATUS_OK         = 'Ok'.freeze
  STATUS_WARNING    = 'Warn'.freeze
  STATUS_ERROR      = 'Error'.freeze
  STATUS_TIMEOUT    = 'Timeout'.freeze
  STATUS_EXPIRED    = 'Expired'.freeze

  DEFAULT_MESSAGE   = 'Initialized'.freeze
  DEFAULT_USERID    = 'system'.freeze

  MESSAGE_TASK_COMPLETED_SUCCESSFULLY   = 'Task completed successfully'.freeze
  MESSAGE_TASK_COMPLETED_UNSUCCESSFULLY = 'Task did not complete successfully'.freeze

  has_one :log_file, :dependent => :destroy
  has_one :binary_blob, :as => :resource, :dependent => :destroy
  has_one :miq_report_result
  has_one :job, :dependent => :destroy

  belongs_to :miq_server

  before_validation :initialize_attributes, :on => :create

  before_destroy :check_active, :check_associations

  virtual_has_one :task_results
  virtual_attribute :state_or_status, :string, :arel => (lambda do |t|
    t.grouping(Arel::Nodes::Case.new(t[:state]).when(STATE_FINISHED).then(t[:status]).else(t[:state]))
  end)

  scope :active,                  ->           { where(:state => STATE_ACTIVE) }
  scope :no_associated_job,       ->           { where.not("id IN (SELECT miq_task_id from jobs)") }
  scope :timed_out,               ->           { where("updated_on < ?", Time.now.utc - ::Settings.task.active_task_timeout.to_i_with_method) }
  scope :with_userid,             ->(userid)   { where(:userid => userid) }
  scope :with_zone,               ->(zone)     { where(:zone => zone) }
  scope :with_updated_on_between, ->(from, to) { where("miq_tasks.updated_on BETWEEN ? AND ?", from, to) }
  scope :with_state,              ->(state)    { where(:state => state) }
  scope :finished,                ->           { with_state('Finished') }
  scope :running,                 ->           { where.not(:state => %w(Finished Waiting_to_start Queued)) }
  scope :queued,                  ->           { with_state(%w(Waiting_to_start Queued)) }
  scope :completed_ok,            ->           { finished.where(:status => 'Ok') }
  scope :completed_warn,          ->           { finished.where(:status => 'Warn') }
  scope :completed_error,         ->           { finished.where(:status => 'Error') }
  scope :no_status_selected,      ->           { running.where.not(:status => %(Ok Error Warn)) }
  scope :with_status_in,          ->(s, *rest) { rest.reduce(MiqTask.send(s)) { |chain, r| chain.or(MiqTask.send(r)) } }

  def self.update_status_for_timed_out_active_tasks
    MiqTask.active.timed_out.no_associated_job.find_each do |task|
      task.update_status(STATE_FINISHED, STATUS_ERROR,
                         "Task [#{task.id}] timed out - not active for more than #{::Settings.task.active_task_timeout.to_i_with_method} seconds")
    end
  end

  def active?
    ![STATE_QUEUED, STATE_FINISHED].include?(state)
  end

  def check_active
    if active?
      _log.warn("Task is active, delete not allowed; id: [#{id}]")
      throw :abort
    end
    _log.info("Task deleted; id: [#{id}]")
    true
  end

  def self.status_ok?(status)
    status.casecmp(STATUS_OK) == 0
  end

  def self.status_error?(status)
    status.casecmp(STATUS_ERROR) == 0
  end

  def self.status_timeout?(status)
    status.casecmp(STATUS_TIMEOUT) == 0
  end

  def self.update_status(taskid, state, status, message)
    task = find_by(:id => taskid)
    task.update_status(state, status, message) unless task.nil?
  end

  def check_associations
    if job && job.is_active?
      _log.warn("Delete not allowed: Task [#{id}] has active job - id: [#{job.id}], guid: [#{job.guid}],")
      throw :abort
    end
    true
  end

  def update_status(state, status, message)
    status = STATUS_ERROR if status == STATUS_EXPIRED
    _log.info("Task: [#{id}] [#{state}] [#{status}] [#{message}]")
    self.status = status
    self.message = message
    self.state = state
    self.started_on ||= Time.now.utc if state == STATE_ACTIVE
    self.miq_server ||= MiqServer.my_server

    save!
  end

  def self.update_message(taskid, message)
    task = find_by(:id => taskid)
    task.update_message(message) unless task.nil?
  end

  def update_message(message)
    _log.info("Task: [#{id}] [#{message}]")
    update_attributes!(:message => message)
  end

  def update_context(context)
    update_attributes!(:context_data => context)
  end

  def message=(message)
    super(message)
  end

  def self.info(taskid, message, pct_complete)
    task = find_by(:id => taskid)
    task.info(message, pct_complete) unless task.nil?
  end

  def info(message, pct_complete)
    update_attributes(:message => message, :pct_complete => pct_complete, :status => STATUS_OK)
  end

  def warn(message)
    update_attributes(:message => message, :status => STATUS_WARNING)
  end

  def self.warn(taskid, message)
    task = find_by(:id => taskid)
    task.warn(message) unless task.nil?
  end

  def error(message)
    update_attributes(:message => message, :status => STATUS_ERROR)
  end

  def self.error(taskid, message)
    task = find_by(:id => taskid)
    task.error(message) unless task.nil?
  end

  def self.state_initialized(taskid)
    task = find_by(:id => taskid)
    task.state_initialized unless task.nil?
  end

  def state_initialized
    update_attributes(:state => STATE_INITIALIZED)
  end

  def self.state_queued(taskid)
    task = find_by(:id => taskid)
    task.state_queued unless task.nil?
  end

  def state_queued
    update_attributes(:state => STATE_QUEUED)
  end

  def self.state_active(taskid)
    task = find_by(:id => taskid)
    task.state_active unless task.nil?
  end

  def state_active
    self.state = STATE_ACTIVE
    self.started_on ||= Time.now.utc
    self.miq_server ||= MiqServer.my_server

    save!
  end

  def self.state_finished(taskid)
    task = find_by(:id => taskid)
    task.state_finished unless task.nil?
  end

  def state_finished
    update_attributes(:state => STATE_FINISHED)
  end

  def state_or_status
    state == STATE_FINISHED ? status : state
  end

  def human_status
    self.class.human_status(state_or_status)
  end

  def results_ready?
    status == STATUS_OK && !task_results.blank?
  end

  def queue_callback(state, status, message, result)
    if status.casecmp(STATUS_OK) == 0
      message = MESSAGE_TASK_COMPLETED_SUCCESSFULLY
    else
      message = MESSAGE_TASK_COMPLETED_UNSUCCESSFULLY if message.blank?
    end

    self.task_results = result unless result.nil?
    update_status(state, status.titleize, message)
  end

  def queue_callback_on_exceptions(state, status, message, result)
    # Only callback if status is not "ok"
    unless status.casecmp(STATUS_OK) == 0
      self.task_results = result unless result.nil?
      update_status(state, STATUS_ERROR, message)
    end
  end

  def task_results
    # support legacy task that saved results in the results column
    return Marshal.load(Base64.decode64(results.split("\n").join)) unless results.nil?
    return miq_report_result.report_results unless miq_report_result.nil?
    unless binary_blob.nil?
      serializer_name = binary_blob.data_type
      serializer_name = "Marshal" unless serializer_name == "YAML" # YAML or Marshal, for now
      serializer = serializer_name.constantize
      return serializer.load(binary_blob.binary)
    end
    nil
  end

  def task_results=(value)
    self.binary_blob   = BinaryBlob.new(:name => "task_results", :data_type => "YAML")
    binary_blob.binary = YAML.dump(value)
  end

  def self.generic_action_with_callback(options, queue_options)
    # Pre-reqs:
    # options hash contains the following required keys:
    #   :action => the human friendly name of the action to be run
    #   :userid => the user this is being run for... aka, the logged on user who invoked the action in the UI
    #
    # queue options is a hash containing the following required keys:
    #   :class_name
    #   :method_name
    #   :args
    # queue_options keys that are not required but may be needed:
    #   :instance_id (if using an instance method...an id)
    #   :queue_name (which queue, priority?)
    #   :zone (zone of the request)
    #   :guid (guid of the server to run the action)
    #   :role (role of the server to run the action)
    #   :msg_timeout => how long you want to wait before pulling the plug on the action (seconds)

    msg =  "Queued the action: [#{options[:action]}] being run for user: [#{options[:userid]}]"
    task = MiqTask.create(
      :name    => options[:action],
      :userid  => options[:userid],
      :state   => STATE_QUEUED,
      :status  => STATUS_OK,
      :message => msg)

    # Set the callback for this task to set the status based on the results of the actions
    queue_options[:miq_callback] = {:class_name => task.class.name, :instance_id => task.id, :method_name => :queue_callback, :args => ['Finished']}
    method_opts = queue_options[:args].first
    method_opts[:task_id] = task.id if method_opts.kind_of?(Hash)
    MiqQueue.put(queue_options)

    # return task id to the UI
    _log.info("Task: [#{task.id}] #{msg}")
    task.id
  end

  def self.wait_for_taskid(task_id, options = {})
    options = options.dup
    options[:sleep_time] ||= 1
    options[:timeout] ||= 0
    task = MiqTask.find(task_id)
    return nil if task.nil?
    begin
      Timeout.timeout(options[:timeout]) do
        while task.state != STATE_FINISHED
          sleep(options[:sleep_time])
          # Code running with Rails QueryCache enabled,
          # need to disable caching for the reload to see updates.
          task.class.uncached { task.reload }
        end
      end
    rescue Timeout::Error
      update_status(task_id, STATE_FINISHED, STATUS_TIMEOUT, "Timed out stalled task.")
      task.reload
    end
    task
  end

  def self.delete_older(ts, condition)
    _log.info("Queuing deletion of tasks older than #{ts} and with condition: #{condition}")
    MiqQueue.submit_job(
      :class_name  => name,
      :method_name => "destroy_older_by_condition",
      :args        => [ts, condition],
    )
  end

  def self.destroy_older_by_condition(ts, condition)
    _log.info("Executing destroy_all for records older than #{ts} and with condition: #{condition}")
    MiqTask.where("updated_on < ?", ts).where(condition).destroy_all
  end

  def self.delete_by_id(ids)
    return if ids.empty?
    _log.info("Queuing deletion of tasks with the following ids: #{ids.inspect}")
    MiqQueue.submit_job(
      :class_name  => name,
      :method_name => "destroy",
      :args        => [ids],
    )
  end

  def self.human_status(state_or_status)
    case state_or_status
    when STATE_INITIALIZED then "Initialized"
    when STATE_QUEUED      then "Queued"
    when STATE_ACTIVE      then "Running"
    # STATE_FINISHED:
    when STATUS_OK         then "Complete"
    when STATUS_WARNING    then "Finished with Warnings"
    when STATUS_ERROR      then "Error"
    when STATUS_TIMEOUT    then "Timed Out"
    else "Unknown"
    end
  end

  def process_cancel
    if job
      job.process_cancel
      _("The selected Task was cancelled")
    else
      _("This task can not be canceled")
      # TODO: implement 'cancel' operation for task
    end
  end

  private

  def initialize_attributes
    self.state ||= STATE_INITIALIZED
    self.status ||= STATUS_OK
    self.message ||= DEFAULT_MESSAGE
    self.userid ||= DEFAULT_USERID
  end
end
