# `dash doctor`'s results as data. Run read-only it leaves out the registry check: that
# check is a `docker login` on every host, which writes the registry credentials there.
class Dash::Diagnostics::Doctor < Dash::Diagnostics::Base
  READ_ONLY_SKIPPED = { check: "registry", reason: "runs docker login on each host, which writes credentials there; run `dash doctor` to include it" }.freeze

  def initialize(read_only: false)
    @read_only = read_only
  end

  private
    def snapshot
      doctor = Dash::Cli::Doctor.new(registry: !@read_only)
      doctor.run

      { successful: doctor.successful?, results: doctor.results.map { |result| result_h(result) }, skipped: (@read_only ? [ READ_ONLY_SKIPPED ] : []) }
    end

    def result_h(result)
      { check: result.check.to_s, target: result.target.to_s, status: result.status.to_s, detail: result.detail.to_s }
    end
end
