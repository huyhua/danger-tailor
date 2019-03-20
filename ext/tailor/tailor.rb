# frozen_string_literal: true

# A wrapper to use Tailor via a Ruby API.
class Tailor
  def initialize(tailor_path = nil)
    @tailor_path = tailor_path
  end

  # Runs tailor
  def run(additional_tailor_args = '', options = {})
    # change pwd before run tailor
    Dir.chdir options.delete(:pwd) if options.key? :pwd

    # run tailor with provided options
    `#{tailor_path} #{tailor_arguments(options, additional_tailor_args)}`
  end

  # Return true if tailor is installed or false otherwise
  def installed?
    File.exist?(tailor_path)
  end

  # Return tailor execution path
  def tailor_path
    @tailor_path || default_tailor_path
  end

  private

  # Parse options into shell arguments how swift expect it to be
  # more information: https://github.com/Carthage/Commandant
  # @param options (Hash) hash containing tailor options
  def tailor_arguments(options, additional_tailor_args)
    (options.
      # filter not null
      reject { |_key, value| value.nil? }.
      # map booleans arguments equal true
      map { |key, value| value.is_a?(TrueClass) ? [key, ''] : [key, value] }.
      # map booleans arguments equal false
      map { |key, value| value.is_a?(FalseClass) ? ["no-#{key}", ''] : [key, value] }.
      # replace underscore by hyphen
      map { |key, value| [key.to_s.tr('_', '-'), value] }.
      # prepend '--' into the argument
      map { |key, value| ["--#{key}", value] }.
      # reduce everything into a single string
      reduce('') { |args, option| "#{args} #{option[0]} #{option[1]}" } +
      " #{additional_tailor_args}").
      # strip leading spaces
      strip
  end

  # Path where tailor should be found
  def default_tailor_path
    '/usr/local/bin/tailor'
  end
end
