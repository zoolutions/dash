# The heartbeat names another controller - one started with `--takeover` - so this one stops.
class Dash::Autoscale::LeaseLost < StandardError; end
