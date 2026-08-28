# frozen_string_literal: true

# Every vault `dash secrets fetch --adapter` supports, what it shells out to,
# and how --account / --from and the secret names are read for each.
class Views::Docs::Pages::SecretsAdapters < DocsUI::Page
  title "Secrets adapters"
  eyebrow "Configuration"

  def lead = "The password managers and secret stores dash secrets fetch can read from."

  ADAPTERS = [
    [ "1password", "one_password", "op", "required — the 1Password account", "vault, or vault/item to fetch every field of an item" ],
    [ "bitwarden", "—", "bw", "required — the login email", "prefix joined to each secret name" ],
    [ "bitwarden-sm", "bitwarden_secrets_manager", "bws", "—", "prefix joined to each secret name (project)" ],
    [ "lastpass", "last_pass", "lpass", "required — the login email", "folder prefix" ],
    [ "aws_secrets_manager", "—", "aws", "optional — an AWS CLI profile", "prefix joined to each secret id" ],
    [ "gcp", "gcp_secret_manager", "gcloud", "required — user, optionally with an impersonation chain", "project" ],
    [ "doppler", "—", "doppler", "—", "project/config (unless DOPPLER_TOKEN is a service token)" ],
    [ "passbolt", "—", "passbolt", "—", "folder prefix" ],
    [ "enpass", "—", "enpass-cli", "—", "required — path to the vault" ]
  ].freeze

  def content
    the_shape
    adapters
    per_adapter
  end

  private

  def the_shape
    DocsUI::Section("The shape") do
      md <<~'MD'
        `.dash/secrets` is a dotenv file with command substitution, and
        `dash secrets fetch` is the substitution: it shells out to the vault's
        own CLI, which must be installed and logged in, and prints the results
        as JSON. `dash secrets extract` pulls one value out of that JSON by
        name — or by the last path segment, so `DB_PASSWORD` matches
        `my-vault/app/DB_PASSWORD`. Fetch once, extract many:
      MD
      DocsUI::Code(<<~SHELL, filename: ".dash/secrets", lexer: :shell)
        SECRETS=$(dash secrets fetch --adapter 1password --account my-team --from Production/app REGISTRY_PASSWORD DB_PASSWORD)

        DASH_REGISTRY_PASSWORD=$(dash secrets extract REGISTRY_PASSWORD $SECRETS)
        DB_PASSWORD=$(dash secrets extract DB_PASSWORD $SECRETS)
      SHELL
      md <<~'MD'
        `--from` is a prefix joined to each name with `/` (so `--from a b` and
        `a/b` are the same request); what the prefix *means* — vault, folder,
        project, path — is up to the adapter. `--account` is required by the
        adapters that log in as someone. Secrets are fetched on the machine
        running dash and never stored on the servers beyond the per-role env
        file; see [Environment](/docs/env) for how they reach containers.
      MD
    end
  end

  def adapters
    DocsUI::Section("Adapters") do
      DocsUI::Table(
        [ "--adapter", "Also", "Shells out to", "--account", "--from" ],
        ADAPTERS.map { |name, aliased, cli, account, from| [ [ :code, name ], aliased == "—" ? "—" : [ :code, aliased ], [ :code, cli ], account, from ] }
      )
      md <<~'MD'
        Adapter names are case-insensitive. The "Also" column is the underlying
        adapter name, accepted as well.
      MD
    end
  end

  def per_adapter
    DocsUI::Section("Per adapter") do
      md <<~'MD'
        ### 1Password

        Secrets are `vault/item/field`, or `vault/item` for the item's
        `password` field; `--from` supplies the leading segments. Results are
        keyed by the `op://` reference minus the prefix. With no secret names
        and `--from vault/item`, every field of that item is fetched. Signs in
        with `op signin` if the account has no session.
      MD
      DocsUI::Code(<<~SHELL, filename: ".dash/secrets", lexer: :shell)
        SECRETS=$(dash secrets fetch --adapter 1password --account my-team --from Production/app REGISTRY_PASSWORD DB_PASSWORD)
      SHELL
      md <<~'MD'
        ### Bitwarden

        Secrets are `item` (its login password) or `item/field` (a custom
        field). Logs in and unlocks the vault interactively when needed, then
        syncs. Results are keyed `item` or `item/field`.
      MD
      DocsUI::Code(<<~SHELL, filename: ".dash/secrets", lexer: :shell)
        SECRETS=$(dash secrets fetch --adapter bitwarden --account you@example.com production-app/REGISTRY_PASSWORD production-app/DB_PASSWORD)
      SHELL
      md <<~'MD'
        ### Bitwarden Secrets Manager

        Authenticates with the `BWS_ACCESS_TOKEN` the `bws` CLI reads. Secrets
        are UUIDs, fetched one by one; or pass the single name `all` to list
        every secret, or `<project>/all` for one project's. Results are keyed
        by the secret's key.
      MD
      DocsUI::Code(<<~SHELL, filename: ".dash/secrets", lexer: :shell)
        SECRETS=$(dash secrets fetch --adapter bitwarden-sm production/all)
      SHELL
      md <<~'MD'
        ### LastPass

        Secrets are item names, optionally under a folder given as `--from`.
        Logs in with `lpass login` when the status does not already show the
        account. Results are keyed by the item's full name; a missing item
        fails the fetch.
      MD
      DocsUI::Code(<<~SHELL, filename: ".dash/secrets", lexer: :shell)
        SECRETS=$(dash secrets fetch --adapter lastpass --account you@example.com --from Production REGISTRY_PASSWORD DB_PASSWORD)
      SHELL
      md <<~'MD'
        ### AWS Secrets Manager

        One `batch-get-secret-value` call for all the ids. A secret whose value
        is a JSON object is flattened to `id/key` entries; anything else is
        kept whole under its id. `--account` selects an AWS CLI `--profile`;
        credentials and region come from the AWS CLI's own configuration.
      MD
      DocsUI::Code(<<~SHELL, filename: ".dash/secrets", lexer: :shell)
        SECRETS=$(dash secrets fetch --adapter aws_secrets_manager --account production --from production app)

        DB_PASSWORD=$(dash secrets extract production/app/DB_PASSWORD $SECRETS)
      SHELL
      md <<~'MD'
        ### Google Cloud Secret Manager

        Secrets are `secret`, `project/secret`, or `project/secret/version`;
        `default` means the gcloud default project, and the version defaults
        to `latest`. `--account` is the user (`default` for the active one),
        optionally followed by `|service-account` to impersonate, and a
        comma-separated delegation chain after that. Runs `gcloud auth login`
        when no account is active. Results are keyed `project/secret`.
      MD
      DocsUI::Code(<<~SHELL, filename: ".dash/secrets", lexer: :shell)
        SECRETS=$(dash secrets fetch --adapter gcp --account default --from my-project REGISTRY_PASSWORD DB_PASSWORD/3)
      SHELL
      md <<~'MD'
        ### Doppler

        With a service token in `DOPPLER_TOKEN` (`dp.st…`), pass bare secret
        names. Otherwise `--from project/config` (or a `project/config/NAME`
        path) selects the project and config, and dash runs `doppler login`
        when you are not logged in.
      MD
      DocsUI::Code(<<~SHELL, filename: ".dash/secrets", lexer: :shell)
        SECRETS=$(dash secrets fetch --adapter doppler --from my-app/prd REGISTRY_PASSWORD DB_PASSWORD)
      SHELL
      md <<~'MD'
        ### Passbolt

        Secrets are resource names, optionally under a folder path (`--from`
        or `folder/sub/NAME`); nested folders are resolved by name. Verifies
        the CLI's configured account with `passbolt verify` first. Results are
        keyed by the resource name.
      MD
      DocsUI::Code(<<~SHELL, filename: ".dash/secrets", lexer: :shell)
        SECRETS=$(dash secrets fetch --adapter passbolt --from Production/app REGISTRY_PASSWORD DB_PASSWORD)
      SHELL
      md <<~'MD'
        ### Enpass

        Offline: `--from` is the path to the vault directory and there is no
        account. Secrets are item titles (every password field of the item) or
        `title/label` (one field). Results are keyed `title/label`.
      MD
      DocsUI::Code(<<~SHELL, filename: ".dash/secrets", lexer: :shell)
        SECRETS=$(dash secrets fetch --adapter enpass --from "$HOME/Library/Containers/in.sinew.Enpass-Desktop/Data/Documents/Vaults/primary" app/DB_PASSWORD)
      SHELL
    end
  end
end
