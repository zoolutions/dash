# The provider could not be asked, or refused. Never carries credentials: providers build
# the message from the request path and the response status, not from the request.
class Dash::Autoscale::ProviderError < StandardError; end
