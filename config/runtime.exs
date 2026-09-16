import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/aerox start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :aerox, AeroxWeb.Endpoint, server: true
end

config :aerox, AeroxWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :aerox, AeroxWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/aerox_web/router\.ex$"E,
        ~r"lib/aerox_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # One URL per repo (DESIGN §4.6): the PDS database and the core database may
  # live on different servers, and nothing may assume otherwise.
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  for {repo, var} <- [
        {Aerox.PDS.Repo, "PDS_DATABASE_URL"},
        {Aerox.PLC.Repo, "PLC_DATABASE_URL"},
        {Aerox.Relay.Repo, "RELAY_DATABASE_URL"},
        {Aerox.AppView.Repo, "APPVIEW_DATABASE_URL"},
        {Aerox.Labeler.Repo, "LABELER_DATABASE_URL"},
        {Aerox.Jetstream.Repo, "JETSTREAM_DATABASE_URL"}
      ] do
    if url = System.get_env(var) do
      config :aerox, repo,
        url: url,
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
        socket_options: maybe_ipv6
    end
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # ------------------------------------------------------------------ services
  # Every value below comes from /etc/aerox/<env>.env (DEV_PLAN §1.3): the file
  # is 0600, loaded by systemd, never in the repo. Hostnames default to
  # <service>.<PHX_HOST>; the PDS answers on PHX_HOST itself.
  service_host = fn name ->
    System.get_env("#{name}_HOST") || "#{String.downcase(name)}.#{host}"
  end

  need = fn var -> System.get_env(var) || raise("environment variable #{var} is missing") end

  config :aerox, :plc_url, System.get_env("PLC_URL") || "https://" <> service_host.("PLC")

  config :aerox,
         :trusted_proxies,
         String.split(System.get_env("TRUSTED_PROXIES", "127.0.0.1"), ",", trim: true)

  labeler_did = System.get_env("LABELER_DID")

  config :aerox, Aerox.PDS,
    public_url: System.get_env("PDS_PUBLIC_URL") || "https://" <> host,
    handle_domains: String.split(System.get_env("HANDLE_DOMAINS", "." <> host), ",", trim: true),
    plc_url: System.get_env("PLC_URL") || "https://" <> service_host.("PLC"),
    oauth_key_hex: need.("OAUTH_KEY_HEX"),
    jwt_secret: need.("JWT_SECRET"),
    # HTTP Basic admin for com.atproto.admin.* (pdsadmin and the admin console);
    # without it only the moderation service's JWT reaches those routes
    admin_password: System.get_env("PDS_ADMIN_PASSWORD"),
    recovery_did_key: System.get_env("RECOVERY_DID_KEY"),
    invites_required: System.get_env("INVITES_REQUIRED", "true") in ~w(true 1),
    contact_email: System.get_env("CONTACT_EMAIL"),
    appview: [
      url: "https://" <> service_host.("APPVIEW"),
      did: "did:web:" <> service_host.("APPVIEW")
    ],
    mod_service: [url: "https://" <> service_host.("LABELER"), did: labeler_did],
    mod_service_did: labeler_did

  # DESIGN §14.2: the rotation key lives in KMS or behind the Remote signer in
  # production; Signer.Local is refused by Aerox.PDS.Config.signer/0.
  signer_config =
    case System.get_env("SIGNER", "remote") do
      "kms" ->
        [
          adapter: Aerox.Crypto.Signer.Kms,
          key_id: need.("KMS_KEY_ID"),
          region: need.("AWS_REGION"),
          access_key_id: need.("AWS_ACCESS_KEY_ID"),
          secret_access_key: need.("AWS_SECRET_ACCESS_KEY"),
          session_token: System.get_env("AWS_SESSION_TOKEN")
        ]

      "remote" ->
        [
          adapter: Aerox.Crypto.Signer.Remote,
          url: need.("SIGNER_URL"),
          secret: need.("SIGNER_SECRET")
        ]

      other ->
        raise "SIGNER must be kms or remote, got #{inspect(other)}"
    end

  config :aerox, Aerox.Crypto.Signer, signer_config

  config :aerox, Aerox.Blob.Store,
    adapter: Aerox.Blob.Disk,
    root: System.get_env("BLOB_ROOT") || "/var/lib/aerox/blobs"

  config :aerox, Aerox.Relay,
    hostname: service_host.("RELAY"),
    public_url: "https://" <> service_host.("RELAY"),
    trusted_domains: String.split(System.get_env("RELAY_TRUSTED_DOMAINS", host), ",", trim: true),
    admin_password: need.("RELAY_ADMIN_PASSWORD")

  config :aerox, Aerox.ImageServer,
    cache_dir: System.get_env("IMAGE_CACHE_DIR") || "/var/lib/aerox/image-cache",
    max_bytes: String.to_integer(System.get_env("IMAGE_CACHE_MAX_BYTES", "4294967296")),
    # The libvips concurrency bound of DESIGN §21.8: how many dirty-scheduler
    # NIF calls may run at once. VERIFICATION §10.1 measures images/s against it.
    concurrency: String.to_integer(System.get_env("IMAGE_CONCURRENCY", "4"))

  config :aerox, Aerox.AppView,
    signing_key_hex: need.("APPVIEW_SIGNING_KEY_HEX"),
    ingest_concurrency: String.to_integer(System.get_env("INGEST_CONCURRENCY", "4")),
    hostname: service_host.("APPVIEW"),
    public_url: "https://" <> service_host.("APPVIEW"),
    relay_url: System.get_env("RELAY_WS_URL") || "wss://" <> service_host.("RELAY"),
    image_cache_dir: System.get_env("IMAGE_CACHE_DIR") || "/var/lib/aerox/image-cache",
    labelers:
      if(labeler_did,
        do: [%{did: labeler_did, url: "wss://" <> service_host.("LABELER")}],
        else: []
      )

  config :aerox, Aerox.Labeler,
    hostname: service_host.("LABELER"),
    public_url: "https://" <> service_host.("LABELER"),
    did: labeler_did,
    signing_key_hex: System.get_env("LABELER_SIGNING_KEY_HEX"),
    admin_password: need.("LABELER_ADMIN_PASSWORD")

  config :aerox, Aerox.Jetstream,
    hostname: service_host.("JETSTREAM"),
    public_url: "https://" <> service_host.("JETSTREAM"),
    relay_url: System.get_env("RELAY_WS_URL") || "wss://" <> service_host.("RELAY"),
    data_dir: System.get_env("JETSTREAM_DATA_DIR") || "/var/lib/aerox/jetstream",
    import_token: System.get_env("JETSTREAM_IMPORT_TOKEN")

  config :aerox, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # The address Bandit listens on. The default binds every interface, which on a
  # host without a packet filter publishes the plaintext HTTP port beside the
  # reverse proxy that is supposed to be the only way in — and TRUSTED_PROXIES
  # then has nothing to check, because the client reaches Phoenix directly. Set
  # BIND_IP to the private address the proxy dials (dev does the same through
  # AEROX_BIND_IP).
  bind_ip =
    case System.get_env("BIND_IP") do
      nil ->
        {0, 0, 0, 0, 0, 0, 0, 0}

      addr ->
        case :inet.parse_address(String.to_charlist(addr)) do
          {:ok, ip} -> ip
          {:error, _} -> raise "BIND_IP is not an IP address: #{inspect(addr)}"
        end
    end

  config :aerox, AeroxWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: bind_ip],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :aerox, AeroxWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :aerox, AeroxWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :aerox, Aerox.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
