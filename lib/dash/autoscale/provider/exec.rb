require "json"
require "open3"

# The operator's own scripts, for any cloud dash has no client for. Each runs locally with
# the role's labels as DASH_SERVICE / DASH_DESTINATION / DASH_ROLE (and their KAMAL_
# twins, as hooks get), plus DASH_MEMBER_ID and DASH_HOST for the member it acts on.
# `members` and `create` print members as JSON, one object per line.
class Dash::Autoscale::Provider::Exec < Dash::Autoscale::Provider::Base
  def initialize(scripts:)
    @scripts = scripts
  end

  # `address` is the script's business: it prints the host dash should connect to.
  def members(labels:, address:)
    run(:members, labels).lines.filter_map { |line| parse_member(line, labels) if line.strip.present? }
      .select { |member| member.role == labels["dash.role"] }
  end

  def start(member)
    run(:start, labels_of(member), member)
  end

  def stop(member, timeout:)
    run(:stop, labels_of(member), member, "DASH_STOP_TIMEOUT" => timeout.to_s)
  end

  def create(labels:, template:, address:)
    parse_member(run(:create, labels).lines.find { |line| line.strip.present? }, labels) ||
      raise(Dash::Autoscale::ProviderError, "exec: create printed no member")
  end

  def destroy(member)
    run(:destroy, labels_of(member), member)
  end

  # The members script is the only source of state there is.
  def state(member)
    members(labels: labels_of(member), address: nil).find { |candidate| candidate.id == member.id }&.state ||
      raise(Dash::Autoscale::ProviderError, "exec: members no longer lists #{member.id}")
  end

  private
    def run(action, labels, member = nil, extra_env = {})
      script = @scripts.call(action) || raise(Dash::Autoscale::ProviderError, "exec: no #{action} script, set autoscale/provider/exec/#{action}")
      output, error, status = Open3.capture3(env(labels, member).merge(extra_env), script)

      unless status.success?
        raise Dash::Autoscale::ProviderError, "exec: #{script} exited #{status.exitstatus}#{": #{last_line(error)}" if error.present?}"
      end

      output
    rescue SystemCallError => e
      raise Dash::Autoscale::ProviderError, "exec: #{script} could not run (#{e.message})"
    end

    def env(labels, member)
      Dash::Tags.new(
        service: labels["dash.service"], destination: labels["dash.destination"], role: labels["dash.role"],
        member_id: member&.id, host: member&.host
      ).env
    end

    def parse_member(line, labels)
      return if line.nil?

      data = JSON.parse(line)
      raise JSON::ParserError unless data.is_a?(Hash)

      if data["id"].to_s.blank? || data["host"].to_s.blank?
        raise Dash::Autoscale::ProviderError, "exec: a member needs an id and a host, got #{line.strip.truncate(80).inspect}"
      end

      state = data["state"].to_s

      unless Dash::Autoscale::Member::STATES.include?(state)
        raise Dash::Autoscale::ProviderError, "exec: member #{data["id"]} has state #{state.inspect}, expected one of #{Dash::Autoscale::Member::STATES.join(", ")}"
      end

      Dash::Autoscale::Member.new(id: data["id"].to_s, host: data["host"], role: data["role"] || labels["dash.role"], state: state,
        labels: labels.merge("dash.role" => data["role"] || labels["dash.role"]), created_at: data["created_at"])
    rescue JSON::ParserError
      raise Dash::Autoscale::ProviderError, "exec: expected one JSON object per line, got #{line.strip.truncate(80).inspect}"
    end

    # The last line says why a script failed; anything above it is the script's own chatter,
    # and the message ends up in errors and saved reports.
    def last_line(output)
      output.lines.map(&:strip).reject(&:blank?).last.to_s.truncate(200)
    end

    def labels_of(member)
      member.labels || raise(Dash::Autoscale::ProviderError, "exec: member #{member.id} carries no labels")
    end
end
