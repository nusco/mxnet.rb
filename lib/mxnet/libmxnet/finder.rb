module MXNet
  module LibMXNet
    module Finder
      case RUBY_PLATFORM
      when /cygwin/
        libprefix = 'cyg'
        libsuffix = 'dll'
      when /mingw/, /mswin/
        libprefix = ''
        libsuffix = 'dll'
      when /darwin/
        libsuffix = 'dylib'
      end

      LIBPREFIX = libprefix || 'lib'
      LIBSUFFIX = libsuffix || 'so'

      module_function

      def find_libmxnet
        top_dir = File.expand_path('../../../..', __FILE__)
        lib_dir = File.join(top_dir, 'lib')
        dll_path = [lib_dir]
        if RUBY_PLATFORM =~ /(?:mingw|mswin|cygwin)/i
          ENV['PATH'].split(';').each do |path|
            dll_path << path.strip
          end
          ENV['PATH'] = "#{lib_dir};#{ENV['PATH']}"
        end
        if RUBY_PLATFORM !~ /(?:mswin|darwin)/i
          if ENV['LD_LIBRARY_PATH']
            ENV['LD_LIBRARY_PATH'].split(':').each do |path|
              dll_path << path.strip
            end
          end
        end
        dll_path.map! {|path| File.join(path, "#{LIBPREFIX}mxnet.#{LIBSUFFIX}") }
        dll_path.unshift(ENV['LIBMXNET'])
        lib_path = dll_path.select {|path| path && File.file?(path) }
        if lib_path.empty?
          raise "Unable to find MXNet shared library.  The list of candidates:\n#{lib_path.join("\n")}"
        end
        lib_path
      end
    end
  end
end
