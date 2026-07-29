# Raised when the config declares a healthcheck the running container does not have.
#
# Deliberately NOT a Kamal::Cli::Healthcheck::Error: the poller retries that class until
# deploy_timeout, and drift is deterministic — `.State.Health` exists from the moment a
# container with a healthcheck is created, so retrying only burns the timeout before
# reporting the same thing.
class Kamal::Cli::Healthcheck::DriftError < StandardError; end
