# Another controller's heartbeat is alive, so this one does not start (`--takeover` overrides).
class Dash::Autoscale::LeaseHeld < StandardError; end
