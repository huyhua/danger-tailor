# frozen_string_literal: true

require 'yaml'
require 'find'
require 'shellwords'
require_relative '../ext/tailor/tailor'

module Danger
  # Shows the build errors, warnings and violations generated from Tailor.
  # You need [Tailor](https://tailor.sh) installed and generating a json file
  # to use this plugin
  #
  # @example Showing summary
  #
  #     tailor -f json MyProject/ > tailor.json
  #     danger-tailor.report 'tailor.json'
  #
  # @example Filter out the pods before analyzing
  #
  #     danger-tailor.ignored_files = '**/Pods/**'
  #     danger-tailor.report 'tailor.json'
  #
  # @see  IntrepidPursuits/danger-tailor
  # @tags xcode, swift, tailor, lint, format, xcodebuild
  #
  class DangerTailor < Plugin
    # The path to Tailor's execution
    attr_accessor :binary_path

    # The path to Tailor's configuration file
    attr_accessor :config_file

    # Allows you to specify a directory from where tailor will be run.
    attr_accessor :directory

    # Provides additional logging diagnostic information.
    attr_accessor :verbose

    # Maximum number of issues to be reported.
    attr_accessor :max_num_violations

    # Whether all files should be linted in one pass
    attr_accessor :lint_all_files

    def report(files = nil, inline_mode: false, fail_on_error: false, additional_tailor_args: '', &select_block)
      # Fails if tailor isn't installed
      raise 'tailor is not installed' unless tailor.installed?

      config_file_path = if config_file
        config_file
      elsif File.file?('.tailor.yml')
        File.expand_path('.tailor.yml')
      end
      log "Using config file: #{config_file_path}"

      dir_selected = directory ? File.expand_path(directory) : Dir.pwd
      log "Tailor will be run from #{dir_selected}"

      # Get config
      config = load_config(config_file_path)

      # Extract excluded paths
      excluded_paths = format_paths(config['excluded'] || [], config_file_path)

      log "Tailor will exclude the following paths: #{excluded_paths}"

      # Extract included paths
      included_paths = format_paths(config['included'] || [], config_file_path)

      log "Tailor includes the following paths: #{included_paths}"

      # Extract swift files (ignoring excluded ones)
      files = find_swift_files(dir_selected, files, excluded_paths, included_paths)
      log "Tailor will lint the following files: #{files.join(', ')}"



      # Prepare Tailor options
      options = {
        # Make sure we don't fail when config path has spaces
        config: config_file_path ? Shellwords.escape(config_file_path) : nil,
        format: 'json',
        pwd: dir_selected
      }
      log "linting with options: #{options}"

      # Lint each file and collect the results
      issues = run_tailor(files, lint_all_files, options, additional_tailor_args)
      other_issues_count = 0
      unless @max_num_violations.nil?
        other_issues_count = issues.count - @max_num_violations if issues.count > @max_num_violations
        issues = issues.take(@max_num_violations)
      end
      log "Received from Tailor: #{issues}"

      # filter out any unwanted violations with the passed in select_block
      if select_block
        issues.select! { |issue| select_block.call(issue) }
      end

      # Filter warnings and errors
      warnings = issues.select { |issue| issue['severity'] == 'warning' }
      errors = issues.select { |issue| issue['severity'] == 'error' }

      if inline_mode
        # Report with inline comment
        send_inline_comment(warnings, :warn)
        send_inline_comment(errors, fail_on_error ? :fail : :warn)
        warn other_issues_message(other_issues_count) if other_issues_count > 0
      elsif warnings.count > 0 || errors.count > 0
        # Report if any warning or error
        message = "### Tailor found issues\n\n".dup
        message << markdown_issues(warnings, 'Warnings') unless warnings.empty?
        message << markdown_issues(errors, 'Errors') unless errors.empty?
        message << "\n#{other_issues_message(other_issues_count)}" if other_issues_count > 0
        markdown message

        # Fail Danger on errors
        if fail_on_error && errors.count > 0
          fail 'Failed due to SwiftLint errors'
        end
      end
    end

    private
    # Get the configuration file
    def load_config(filepath)
      return {} if filepath.nil? || !File.exist?(filepath)

      config_file = File.open(filepath).read

      YAML.safe_load(config_file)
    end

    # Run swiftlint on each file and aggregate collect the issues
    #
    # @return [Array] swiftlint issues
    def run_tailor(files, lint_all_files, options, additional_tailor_args)
      if lint_all_files
        result = tailor.run('.', options, additional_swiftlint_args)
        if result == ''
          {}
        else
          JSON.parse(result)['files']
          .map { |s| s['violations'].map {|v| v['path'] = s['path']; v } }
          .flatten
        end
      else
        files
        .map { |file| tailor.run(file, options, additional_tailor_args) }
        .reject { |s| s == '' }
        .map { |s| JSON.parse(s)['files'].first }
        .map { |s| s['violations'].map {|v| v['path'] = s['path']; v } }
        .flatten
      end
    end

    # Find swift files from the files glob
    # If files are not provided it will use git modifield and added files
    #
    # @return [Array] swift files
    def find_swift_files(dir_selected, files = nil, excluded_paths = [], included_paths = [])
      # Needs to be escaped before comparsion with escaped file paths
      dir_selected = Shellwords.escape(dir_selected)

      # Assign files to lint
      files = if files.nil?
        (git.modified_files - git.deleted_files) + git.added_files
      else
        Dir.glob(files)
      end
      # Filter files to lint
      files.
      # Ensure only swift files are selected
      select { |file| file.end_with?('.swift') }.
      # Make sure we don't fail when paths have spaces
      map { |file| Shellwords.escape(File.expand_path(file)) }.
      # Remove dups
      uniq.
      # Ensure file must exist to continue
      select { |file| File.exist? file }
      # Ensure only files in the selected directory
      select { |file| file.start_with?(dir_selected) }.
      # Reject files excluded on configuration
      reject { |file| file_exists?(excluded_paths, file) }.
      # Accept files included on configuration
      select do |file|
        next true if included_paths.empty?
        file_exists?(included_paths, file)
      end
    end

    # Return whether the file exists within a specified collection of paths
    #
    # @return [Bool] file exists within specified collection of paths
    def file_exists?(paths, file)
      paths.any? do |path|
        Find.find(path)
        .map { |path_file| Shellwords.escape(path_file) }
        .include?(file)
      end
    end

    # Parses the configuration file and return the specified files in path
    #
    # @return [Array] list of files specified in path
    def format_paths(paths, filepath)
      # Extract included paths
      paths
      .map { |path| File.join(File.dirname(filepath), path) }
      .map { |path| File.expand_path(path) }
      .select { |path| File.exist?(path) || Dir.exist?(path) }
    end

    # Create a markdown table from swiftlint issues
    #
    # @return  [String]
    def markdown_issues(results, heading)
      message = "#### #{heading}\n\n".dup

      message << "File | Line | Reason |\n"
      message << "| --- | ----- | ----- |\n"

      results.each do |r|
        filename = r['path'].split('/').last
        line = r['location']['line']
        reason = r['message']
        rule = r['rule']
        message << "#{filename} | #{line} | #{reason} (#{rule})\n"
      end

      message
    end

    # Send inline comment with danger's warn or fail method
    #
    # @return [void]
    def send_inline_comment(results, method)
      dir = "#{Dir.pwd}/"
      results.each do |r|
        github_filename = r['path'].gsub(dir, '')
        message = "#{r['message']}".dup

        # extended content here
        filename = r['path'].split('/').last
        message << "\n"
        message << "`#{r['rule']}`" # helps writing exceptions // swiftlint:disable:this rule_id
        message << " `#{filename}:#{r['location']['line']}`" # file:line for pasting into Xcode Quick Open

        send(method, message, file: github_filename, line: r['location']['line'])
      end
    end

    def other_issues_message(issues_count)
      violations = issues_count == 1 ? 'violation' : 'violations'
      "Tailor also found #{issues_count} more #{violations} with this PR."
    end

    # Make Tailor object for binary_path
    #
    # @return [Tailor]
    def tailor
      Tailor.new(binary_path)
    end

    def log(text)
      puts(text) if @verbose
    end
  end
end
