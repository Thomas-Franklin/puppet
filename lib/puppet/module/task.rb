require 'puppet/util/logging'

class Puppet::Module
  class Task
    class Error < Puppet::Error
      attr_accessor :kind, :details
      def initialize(message, kind, details = nil)
        super(message)
        @details = details || {}
        @kind = kind
      end

      def to_h
        {
          msg: message,
          kind: kind,
          details: details
        }
      end
    end

    class InvalidName < Error
      def initialize(name)
        msg = _("Task names must start with a lowercase letter and be composed of only lowercase letters, numbers, and underscores")
        super(msg, 'puppet.tasks/invalid-name')
      end
    end

    class InvalidFile < Error
      def initialize(msg)
        super(msg, 'puppet.tasks/invalid-file')
      end
    end

    class InvalidTask < Error
    end
    class InvalidMetadata < Error
    end
    class TaskNotFound < Error
      def initialize(task_name, module_name)
        msg = _("Task %{task_name} not found in module %{module_name}.") %
          {task_name: task_name, module_name: module_name}
        super(msg, 'puppet.tasks/task-not-found', { 'name' => task_name })
      end
    end

    FORBIDDEN_EXTENSIONS = %w{.conf .md}
    MOUNTS = %w[lib files tasks]

    def self.is_task_name?(name)
      return true if name =~ /^[a-z][a-z0-9_]*$/
      return false
    end

    # Determine whether a file has a legal name for either a task's executable or metadata file.
    def self.is_tasks_filename?(path)
      name_less_extension = File.basename(path, '.*')
      return false if not is_task_name?(name_less_extension)
      FORBIDDEN_EXTENSIONS.each do |ext|
        return false if path.end_with?(ext)
      end
      return true
    end

    def self.get_file_details(path, mod)
      # This gets the path from the starting point onward
      # For files this should be the file subpath from the metadata
      # For directories it should be the directory subpath plus whatever we globbed
      # Partition matches on the first instance it finds of the parameter
      name = "#{mod.name}#{path.partition(mod.path).last}"

      { "name" => name, "path" =>  path }
    end

    # Find task's required lib files and retrieve paths
    # for both 'files' and 'implementation:files' metadata keys
    def self.find_files(files, mod)
      env = mod.environment.respond_to?(:name) ? mod.environment.name : 'production'

      file_list = files.flat_map do |file|
        module_name, mount, endpath = file.split("/", 3)
        # If there's a mount directory with no trailing slash this will be nil
        # We want it to be empty to construct a path
        endpath ||= ''

        pup_module = Puppet::Module.find(module_name, env)
        if pup_module.nil?
          msg = _("Could not find module %{module_name} containing task file %{filename}" %
                  {module_name: module_name, filename: endpath})
          raise InvalidMetadata.new(msg, 'puppet.tasks/invalid-metadata')
        end

        unless MOUNTS.include? mount
          msg = _("Files must be saved in module directories that Puppet makes available via mount points: %{mounts}" %
                  {mounts: MOUNTS.join(', ')})
          raise InvalidMetadata.new(msg, 'puppet.tasks/invalid-metadata')
        end

        path = File.join(pup_module.path, mount, endpath)
        unless File.absolute_path(path) == File.path(path).chomp('/')
          msg = _("File pathnames cannot include relative paths")
          raise InvalidMetadata.new(msg, 'puppet.tasks/invalid-metadata')
        end

        unless File.exist?(path)
          msg = _("Could not find %{path} on disk" % { path: path })
          raise InvalidFile.new(msg)
        end

        last_char = file[-1] == '/'
        if File.directory?(path)
          unless last_char
            msg = _("Directories specified in task metadata must include a trailing slash: %{dir}" % { dir: file } )
            raise InvalidMetadata.new(msg, 'puppet.tasks/invalid-metadata')
          end
          dir_files = Dir.glob("#{path}**/*").select { |f| File.file?(f) }
          files = dir_files.map { |f| get_file_details(f, pup_module) }
        else
          if last_char
            msg = _("Files specified in task metadata cannot include a trailing slash: %{file}" % { file: file } )
            raise InvalidMetadata.new(msg, 'puppet.task/invalid-metadata')
          end
          files = get_file_details(path, pup_module)
        end

        files
      end
      return file_list
    end

    # Copied from TaskInstantiator so we can use the Error classes here
    # TODO: harmonize on one implementation
    # Executables list should contain the full path of all possible implementation files
    def self.find_implementations(name, directory, metadata, executables)
      basename = name.split('::')[1] || 'init'
      # If 'implementations' is defined, it needs to mention at least one
      # implementation, and everything it mentions must exist.
      metadata ||= {}
      if metadata.key?('implementations')
        unless metadata['implementations'].is_a?(Array)
          msg = _("Task metadata for task %{name} does not specify implementations as an array" % { name: name })
          raise InvalidMetadata.new(msg, 'puppet.tasks/invalid-metadata')
        end

        implementations = metadata['implementations'].map do |impl|
          path = executables.find { |real_impl| File.basename(real_impl) == impl['name'] }
          unless path
            msg = _("Task metadata for task %{name} specifies missing implementation %{implementation}" % { name: name, implementation: impl['name'] })
            raise InvalidTask.new(msg, 'puppet.tasks/missing-implementation', { missing: [impl['name']] } )
          end
          { "name" => impl['name'], "requirements" => impl.fetch('requirements', []), "path" => path }
        end
        return implementations
      end

      # If implementations isn't defined, then we use executables matching the
      # task name, and only one may exist.
      implementations = executables.select { |impl| File.basename(impl, '.*') == basename }
      if implementations.empty?
        msg = _('No source besides task metadata was found in directory %{directory} for task %{name}') %
          { name: name, directory: directory }
        raise InvalidTask.new(msg, 'puppet.tasks/no-implementation')
      elsif implementations.length > 1
        msg =_("Multiple executables were found in directory %{directory} for task %{name}; define 'implementations' in metadata to differentiate between them") %
          { name: name, directory: implementations[0] }
        raise InvalidTask.new(msg, 'puppet.tasks/multiple-implementations')
      end

      [{ "name" => File.basename(implementations.first), "path" => implementations.first, "requirements" => [] }]
    end

    def self.is_tasks_metadata_filename?(name)
      is_tasks_filename?(name) && name.end_with?('.json')
    end

    def self.is_tasks_executable_filename?(name)
      is_tasks_filename?(name) && !name.end_with?('.json')
    end

    def self.tasks_in_module(pup_module)
      task_files = Dir.glob(File.join(pup_module.tasks_directory, '*'))
        .keep_if { |f| is_tasks_filename?(f) }

      module_executables = task_files.reject(&method(:is_tasks_metadata_filename?)).map.to_a

      tasks = task_files.group_by { |f| task_name_from_path(f) }

      tasks.map do |task, executables|
        new_with_files(pup_module, task, executables, module_executables)
      end
    end

    attr_reader :name, :module, :metadata_file, :metadata

    # file paths must be relative to the modules task directory
    def initialize(pup_module, task_name,  module_executables, metadata_file = nil)
      if !Puppet::Module::Task.is_task_name?(task_name)
        raise InvalidName, _("Task names must start with a lowercase letter and be composed of only lowercase letters, numbers, and underscores")
      end

      name = task_name == "init" ? pup_module.name : "#{pup_module.name}::#{task_name}"

      @module = pup_module
      @name = name
      @metadata_file = metadata_file
      @module_executables = module_executables || []
    end

    def read_metadata(file)
      Puppet::Util::Json.load(Puppet::FileSystem.read(file, :encoding => 'utf-8')) if file
    rescue SystemCallError, IOError => err
      msg = _("Error reading metadata: %{message}" % {message: err.message})
      raise InvalidMetadata.new(msg, 'puppet.tasks/unreadable-metadata')
    rescue Puppet::Util::Json::ParseError => err
      raise InvalidMetadata.new(err.message, 'puppet.tasks/unparseable-metadata')
    end

    def metadata
      @metadata ||= read_metadata(@metadata_file)
    end

    def implementations
      @implementations ||= self.class.find_implementations(@name, @module.tasks_directory, metadata, @module_executables)
    end

    def files
      md = metadata
      outer_files = []
      impl_lib_files = []
      lib_files = []

      unless md.nil?
        outer_files = md['files'] if md.key?('files')
        # There's definitely a more elegant way to do this...
        if md.key?('implementations')
          md['implementations'].each { |impl| impl_lib_files << impl['files'] if impl.key?('files') }
        end
        lib_files = self.class.find_files((impl_lib_files.flatten.uniq + outer_files).uniq, @module)
      end
      task_file = implementations.map {|imp| { 'name' => imp['name'], 'path' => imp['path'] } }
      # PXP agent relies on 'impls' (which is the task file) being first if there is no metadata
      task_file + lib_files
    end

    def validate
      implementations
      true
    end

    def ==(other)
      self.name == other.name &&
      self.module == other.module
    end

    def self.new_with_files(pup_module, name, task_files, module_executables)
      metadata_file = task_files.find { |f| is_tasks_metadata_filename?(f) }
      Puppet::Module::Task.new(pup_module, name, module_executables, metadata_file)
    end
    private_class_method :new_with_files

    # Abstracted here so we can add support for subdirectories later
    def self.task_name_from_path(path)
      return File.basename(path, '.*')
    end
    private_class_method :task_name_from_path
  end
end
