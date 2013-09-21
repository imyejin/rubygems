#--
# Copyright 2006 by Chad Fowler, Rich Kilmer, Jim Weirich and others.
# All rights reserved.
# See LICENSE.txt for permissions.
#++

require 'rubygems/user_interaction'
require 'thread'

class Gem::Ext::Builder

  include Gem::UserInteraction

  ##
  # The builder shells-out to run various commands after changing the
  # directory.  This means multiple installations cannot be allowed to build
  # extensions in parallel as they may change each other's directories leading
  # to broken extensions or failed installations.

  CHDIR_MUTEX = Mutex.new # :nodoc:

  attr_accessor :build_args # :nodoc:

  def self.class_name
    name =~ /Ext::(.*)Builder/
    $1.downcase
  end

  def self.make(dest_path, results)
    unless File.exist? 'Makefile' then
      raise Gem::InstallError, "Makefile not found:\n\n#{results.join "\n"}"
    end

    # try to find make program from Ruby configure arguments first
    RbConfig::CONFIG['configure_args'] =~ /with-make-prog\=(\w+)/
    make_program = ENV['MAKE'] || ENV['make'] || $1
    unless make_program then
      make_program = (/mswin/ =~ RUBY_PLATFORM) ? 'nmake' : 'make'
    end

    destdir = '"DESTDIR=%s"' % ENV['DESTDIR'] if RUBY_VERSION > '2.0'

    ['', 'install'].each do |target|
      # Pass DESTDIR via command line to override what's in MAKEFLAGS
      cmd = [
        make_program,
        destdir,
        target
      ].join(' ').rstrip
      run(cmd, results, "make #{target}".rstrip)
    end
  end

  def self.redirector
    '2>&1'
  end

  def self.run(command, results, command_name = nil)
    verbose = Gem.configuration.really_verbose

    begin
      # TODO use Process.spawn when ruby 1.8 support is dropped.
      rubygems_gemdeps, ENV['RUBYGEMS_GEMDEPS'] = ENV['RUBYGEMS_GEMDEPS'], nil
      if verbose
        puts(command)
        system(command)
      else
        results << command
        results << `#{command} #{redirector}`
      end
    ensure
      ENV['RUBYGEMS_GEMDEPS'] = rubygems_gemdeps
    end

    unless $?.success? then
      results << "Building has failed. See above output for more information on the failure." if verbose
      raise Gem::InstallError, "#{command_name || class_name} failed:\n\n#{results.join "\n"}"
    end
  end

  ##
  # Creates a new extension builder for +spec+.  If the +spec+ does not yet
  # have build arguments, saved, set +build_args+ which is an ARGV-style
  # array.

  def initialize spec, build_args
    @spec       = spec
    @build_args = build_args
    @gem_dir    = spec.gem_dir

    @ran_rake   = nil
  end

  ##
  # Chooses the extension builder class for +extension+

  def builder_for extension # :nodoc:
    case extension
    when /extconf/ then
      Gem::Ext::ExtConfBuilder
    when /configure/ then
      Gem::Ext::ConfigureBuilder
    when /rakefile/i, /mkrf_conf/i then
      @ran_rake = true
      Gem::Ext::RakeBuilder
    when /CMakeLists.txt/ then
      Gem::Ext::CmakeBuilder
    else
      extension_dir = File.join @gem_dir, File.dirname(extension)

      message = "No builder for extension '#{extension}'"
      build_error extension_dir, message
    end
  end

  ##
  # Logs the build +output+ in +build_dir+, then raises ExtensionBuildError.

  def build_error build_dir, output, backtrace = nil # :nodoc:
    gem_make_out = File.join @spec.extension_install_dir, 'gem_make.out'

    FileUtils.mkdir_p @spec.extension_install_dir

    open gem_make_out, 'wb' do |io| io.puts output end

    message = <<-EOF
ERROR: Failed to build gem native extension.

    #{output}

Gem files will remain installed in #{@gem_dir} for inspection.
Results logged to #{gem_make_out}
EOF

    raise Gem::Installer::ExtensionBuildError, message, backtrace
  end

  def build_extension extension, dest_path # :nodoc:
    results = []

    extension ||= '' # I wish I knew why this line existed
    extension_dir =
      File.expand_path File.join @gem_dir, File.dirname(extension)

    builder = builder_for extension

    begin
      FileUtils.mkdir_p dest_path

      CHDIR_MUTEX.synchronize do
        Dir.chdir extension_dir do
          results = builder.build(extension, @gem_dir, dest_path,
                                  results, @build_args)

          say results.join("\n") if Gem.configuration.really_verbose
        end
      end
    rescue
      build_error extension_dir, results.join("\n"), $@
    end
  end

  ##
  # Builds extensions.  Valid types of extensions are extconf.rb files,
  # configure scripts and rakefiles or mkrf_conf files.

  def build_extensions
    return if @spec.extensions.empty?

    if @build_args.empty?
      say "Building native extensions.  This could take a while..."
    else
      say "Building native extensions with: '#{@build_args.join ' '}'"
      say "This could take a while..."
    end

    dest_path = @spec.extension_install_dir

    @ran_rake = false # only run rake once

    @spec.extensions.each do |extension|
      break if @ran_rake

      build_extension extension, dest_path
    end
  end

end

