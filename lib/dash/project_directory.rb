# Where a project keeps its dash-owned files - secrets and hooks - in the
# operator's own repository. Renamed from `.kamal` in stage 3a of the server
# artifact rename (zoolutions/dash#118); `.kamal` stays readable until 5.0 so an
# upgrade doesn't turn every existing project into a missing-secret error.
#
# Deliberately not memoized: `dash migrate` moves the directory inside a single
# process, and a cached answer would be stale for the rest of that invocation.
class Dash::ProjectDirectory
  CURRENT = ".dash"
  LEGACY = ".kamal"

  class << self
    def path
      legacy? ? LEGACY : CURRENT
    end

    # The predicate tests the directory rather than a specific file: a project
    # holding only `secrets-common` or `secrets.<destination>` must still
    # resolve, and Dash::Secrets synthesizes those names from the base path.
    def legacy?
      !Dir.exist?(CURRENT) && Dir.exist?(LEGACY)
    end

    def join(*parts)
      File.join(path, *parts)
    end
  end
end
