# The provider could not be asked, or refused. dash never puts a credential in the message:
# UpCloud errors carry the request path and the response status, exec errors the script
# name and the last line of its stderr - which is the operator's script to keep clean.
class Dash::Autoscale::ProviderError < StandardError; end
