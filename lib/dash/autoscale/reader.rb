# Reads a signalled role's signal and guards for one evaluation, through the process's
# Dash::Autoscale::Connections. The controller hands Dash::Autoscale::Evaluation one; tests
# hand it a fake.
class Dash::Autoscale::Reader
  def initialize(connections = Dash::Autoscale::Connections.shared)
    @connections = connections
  end

  # [ the signal's Sample, the guards' Dash::Autoscale::Guard::Readings ]
  def read(role, at:)
    [ Dash::Autoscale::Signal.for(role, @connections).sample(at: at), Dash::Autoscale::Guard.read(role.scale.guards, @connections, at: at) ]
  end

  def close
    @connections.close
  end
end
