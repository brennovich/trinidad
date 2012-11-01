require File.expand_path('../../spec_helper', File.dirname(__FILE__))

describe Trinidad::Lifecycle::Host do
  
  class SimpleServer < Trinidad::Server
    def initialize(tomcat)
      @tomcat = tomcat
    end
  end
  
  before do 
    work = File.expand_path('tmp', MOCK_WEB_APP_DIR)
    FileUtils.rm_rf(work) if File.exist?(work)
  end
  
  let(:monitor) { File.expand_path('restart.txt', MOCK_WEB_APP_DIR) }
  let(:server) { SimpleServer.new(tomcat) }
  let(:tomcat) { org.apache.catalina.startup.Tomcat.new }
  let :context do
    context = org.apache.catalina.core.StandardContext.new
    context.setPath('/foo'); context.setParent(tomcat.host)
    context
  end

  let(:before_start_event) do
    Trinidad::Tomcat::LifecycleEvent.new(context,
      Trinidad::Tomcat::Lifecycle::BEFORE_START_EVENT, nil)
  end

  let(:periodic_event) do
    Trinidad::Tomcat::LifecycleEvent.new(context,
      Trinidad::Tomcat::Lifecycle::PERIODIC_EVENT, nil)
  end

  let(:listener) do
    web_app = mock('web_app')
    web_app.stubs(:monitor).returns(monitor)
    app_holder = Trinidad::WebApp::Holder.new(web_app, context)
    Trinidad::Lifecycle::Host.new(server, app_holder)
  end

  it "creates the monitor file when receives a before start event" do
    FileUtils.rm monitor if File.exist?(monitor)
    
    listener.lifecycleEvent(before_start_event)
    sleep(1)
    File.exist?(monitor).should be true
  end

  it "does not create the monitor if already exists" do
    FileUtils.touch monitor
    mtime = File.mtime(monitor)
    sleep(1)
    
    listener.lifecycleEvent(before_start_event)
    File.mtime(monitor).should == mtime
  end

  it "creates the parent directory if it doesn't exist" do
    listener.lifecycleEvent(before_start_event)
    sleep(1)

    File.exist?(monitor).should be true
  end

  it "triggers application reload if monitor changes" do
    listener.lifecycleEvent(before_start_event)
    sleep(1)
    FileUtils.touch(monitor)

    listener.expects(:reload_application!).returns(true)
    listener.lifecycleEvent(periodic_event)
  end
  
  private
  
  def create_web_app(context_path_or_config = '/')
    config = context_path_or_config.is_a?(Hash) ? context_path_or_config : {}
    context_path = context_path_or_config.is_a?(String) && context_path_or_config
    config = {
      :context_path => context_path || '/', 
      :root_dir => MOCK_WEB_APP_DIR, :public => 'assets',
      :monitor => monitor
    }.merge(config)
    Trinidad::WebApp.create({}, config)
  end
  
  def set_file_mtime(path, mtime)
    if mtime.is_a?(Time)
      mtime = mtime.to_f * 1000
    elsif mtime < 0 # -1 seconds
      mtime = java.lang.System.currentTimeMillis + (mtime * 1000)
    end
    file = java.io.File.new(path); file.setLastModified(mtime)
  end
  
  describe 'RestartReload' do
    
    it "updates monitor mtime" do
      web_app = create_web_app
      app_holder = Trinidad::WebApp::Holder.new(web_app, context)
      
      listener = Trinidad::Lifecycle::Host.new(server, app_holder)
      listener.lifecycleEvent before_start_event
      app_holder.monitor_mtime.should_not be nil
      monitor_mtime = app_holder.monitor_mtime
      
      sleep(1)
      FileUtils.touch(monitor)

      context.stubs(:reload)
      listener.lifecycleEvent periodic_event

      app_holder.monitor_mtime.should_not == monitor_mtime
      app_holder.monitor_mtime.should == File.mtime(monitor)
    end
    
    it 'reloads the (very same) context' do
      web_app = create_web_app
      app_holder = Trinidad::WebApp::Holder.new(web_app, context)
      set_file_mtime(monitor, -1.5)
      listener = Trinidad::Lifecycle::Host.new(server, app_holder)
      listener.lifecycleEvent before_start_event

      app_holder.locked?.should be false

      FileUtils.touch(monitor)

      context.expects(:reload)
      listener.lifecycleEvent periodic_event
      app_holder.locked?.should be false
    end
    
    private
    
    def create_web_app(config = {})
      super(config.merge(:reload_strategy => :restart))
    end
    
  end
  
  describe 'RollingReload' do

    it "updates monitor mtime (once context gets replaced)" do
      web_app = create_web_app
      app_holder = Trinidad::WebApp::Holder.new(web_app, context)
      set_file_mtime(monitor, -1.0)
      listener = Trinidad::Lifecycle::Host.new(server, app_holder)
      listener.lifecycleEvent before_start_event
      app_holder.monitor_mtime.should_not be nil
      monitor_mtime = app_holder.monitor_mtime

      FileUtils.touch(monitor)

      listener.lifecycleEvent periodic_event

      app_holder.monitor_mtime.should_not == monitor_mtime
      app_holder.monitor_mtime.should == File.mtime(monitor)
    end

    it "creates a new JRuby class loader for the new context" do
      web_app = create_web_app
      class_loader = web_app.class_loader
      app_holder = Trinidad::WebApp::Holder.new(web_app, context)

      listener = Trinidad::Lifecycle::Host.new(server, app_holder)
      listener.lifecycleEvent before_start_event

      sleep(1)
      File.new(monitor, File::CREAT|File::TRUNC)

      listener.lifecycleEvent periodic_event

      web_app.class_loader.should_not == class_loader
    end
    
    it "creates a new context that takes over the original one" do
      web_app = create_web_app
      app_holder = Trinidad::WebApp::Holder.new(web_app, context)
      set_file_mtime(monitor, -1.5)
      listener = Trinidad::Lifecycle::Host.new(server, app_holder)
      listener.lifecycleEvent before_start_event

      File.new(monitor, File::CREAT|File::TRUNC)

      listener.lifecycleEvent periodic_event

      app_holder.context.should be_a(Trinidad::Tomcat::StandardContext)
      app_holder.context.should_not == context
    end

    it "starts up the newly created context in another thread" do
      web_app = create_web_app
      app_holder = Trinidad::WebApp::Holder.new(web_app, context)
      set_file_mtime(monitor, -1.0)
      listener = Trinidad::Lifecycle::Host.new(server, app_holder)
      listener.lifecycleEvent before_start_event

      app_holder.locked?.should be false

      FileUtils.touch(monitor)

      Thread.expects(:new).yields do
        app_holder.locked?.should be true
      end
      listener.lifecycleEvent periodic_event

      sleep(1) # til Thread.new kicks in
      app_holder.locked?.should be false
      app_holder.context.state_name.should == 'STARTED'
    end
    
    private
    
    def create_web_app(config = {})
      super(config.merge(:reload_strategy => :rolling))
    end
    
    describe 'Takeover' do

      Takeover = Trinidad::Lifecycle::Host::RollingReload::Takeover
      
      let(:new_context) { Trinidad::Tomcat::StandardContext.new }
      let(:old_context) { Trinidad::Tomcat::StandardContext.new }

      let(:takeover) { Takeover.new(old_context) }

      let(:after_start_event) do
        Trinidad::Tomcat::LifecycleEvent.new(new_context,
          Trinidad::Tomcat::Lifecycle::AFTER_START_EVENT, nil)
      end

      it "stops and destroys the (old) context" do
        old_context.expects(:stop).once
        old_context.expects(:destroy).once
        takeover.lifecycleEvent(after_start_event)
      end

      it "change the context's name for the original one" do
        old_context.stubs(:stop)
        old_context.stubs(:destroy)
        old_context.name = 'foo'
        takeover.lifecycleEvent(after_start_event)
        new_context.name.should == 'foo'
      end

      work_dir = File.expand_path('work', MOCK_WEB_APP_DIR)

      before do
        FileUtils.mkdir work_dir unless File.exist?(work_dir)
      end

      after do
        FileUtils.rm_rf(work_dir) if File.exist?(work_dir)
      end

      it "does not delete working directory", :integration => true do
        #context = tomcat.addWebapp(web_app.context_path, web_app.web_app_dir)
        web_app = create_web_app :work_dir => work_dir, :root_dir => MOCK_WEB_APP_DIR
        old_context.name = 'default'
        old_context.path = '/'
        old_context.parent = tomcat.host
        old_context.addLifecycleListener config = Trinidad::Tomcat::ContextConfig.new
        old_context.addLifecycleListener web_app.define_lifecycle
        Trinidad::Tomcat::Tomcat.initWebappDefaults(old_context)
        old_context.start
        config.getServer.start # make sure it's available @see ContextConfig#destroy
        #puts s = config.getServer
        #puts s.getState().isAvailable()
          
        takeover.lifecycleEvent(after_start_event)
        expect( File.exist?(work_dir) ).to be true
      end
      
    end

  end
  
end
