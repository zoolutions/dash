require "concurrent/ivar"

class Dash::Cli::Healthcheck::Barrier
  def initialize
    @ivar = Concurrent::IVar.new
  end

  def close
    set(false)
  end

  def open
    set(true)
  end

  def wait
    unless opened?
      raise Dash::Cli::Healthcheck::Error.new("Halted at barrier")
    end
  end

  private
    def opened?
      @ivar.value
    end

    def set(value)
      @ivar.set(value)
      true
    rescue Concurrent::MultipleAssignmentError
      false
    end
end
