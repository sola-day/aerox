defmodule AeroxWeb.Router do
  use AeroxWeb, :router

  # DESIGN §2: XRPC, the PLC REST surface and the well-known routes are API
  # pipelines of their own; :browser serves only LiveDashboard and the OAuth
  # pages. Every XRPC route is declared explicitly per NSID; the parity table
  # in test/parity/ENDPOINTS.md is read by a router test.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AeroxWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :plc do
    plug :accepts, ["json"]
    plug AeroxWeb.Plugs.ServiceEnabled, :plc
  end

  pipeline :xrpc do
    plug AeroxWeb.Plugs.CORS
    plug :accepts, ["json", "cbor", "car"]
    plug AeroxWeb.Plugs.ClientIP
    plug AeroxWeb.Plugs.RateLimit, :global_ip
    plug AeroxWeb.Plugs.Auth
  end

  pipeline :pds do
    plug AeroxWeb.Plugs.ServiceEnabled, :pds
  end

  pipeline :oauth_api do
    plug AeroxWeb.Plugs.CORS
    plug :accepts, ["json"]
    plug AeroxWeb.Plugs.ClientIP
    plug AeroxWeb.Plugs.RateLimit, :global_ip
    plug AeroxWeb.Plugs.ServiceEnabled, :pds
  end

  pipeline :well_known do
    plug AeroxWeb.Plugs.CORS
    plug AeroxWeb.Plugs.ServiceEnabled, :pds
  end

  scope "/", AeroxWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/.well-known", AeroxWeb.WellKnown do
    pipe_through :well_known

    get "/atproto-did", WellKnownController, :atproto_did
    get "/did.json", WellKnownController, :did_json
  end

  # OAuth authorization server (DESIGN §11.2): JSON endpoints on the API
  # pipeline, consent pages on :browser.
  scope "/", AeroxWeb do
    pipe_through :well_known
    get "/.well-known/oauth-authorization-server", OAuthController, :server_metadata
    get "/.well-known/oauth-protected-resource", OAuthController, :protected_resource
  end

  scope "/oauth", AeroxWeb do
    pipe_through :oauth_api
    get "/jwks", OAuthController, :jwks
    post "/par", OAuthController, :par
    post "/token", OAuthController, :token
    post "/revoke", OAuthController, :revoke
    options "/*path", OAuthController, :jwks
  end

  scope "/oauth", AeroxWeb do
    pipe_through :browser
    get "/authorize", OAuthController, :authorize
    post "/authorize/sign-in", OAuthController, :sign_in
    post "/authorize/accept", OAuthController, :accept
    post "/authorize/reject", OAuthController, :reject
  end

  scope "/xrpc", AeroxWeb.PDS do
    pipe_through [:xrpc, :pds]

    # browser preflights (answered by AeroxWeb.Plugs.CORS in the pipeline)
    options "/*path", ProxyController, :preflight

    # Liveness. Upstream's PDS answers here, so anything already pointed at an
    # atproto PDS finds it; it must be declared before the proxy catch-all at
    # the bottom of this router, which would otherwise swallow it.
    get "/_health", ServerController, :health

    # com.atproto.server
    get "/com.atproto.server.describeServer", ServerController, :describe_server
    post "/com.atproto.server.createAccount", ServerController, :create_account
    post "/com.atproto.server.createSession", ServerController, :create_session
    post "/com.atproto.server.refreshSession", ServerController, :refresh_session
    post "/com.atproto.server.deleteSession", ServerController, :delete_session
    get "/com.atproto.server.getSession", ServerController, :get_session
    get "/com.atproto.server.getServiceAuth", ServerController, :get_service_auth
    post "/com.atproto.server.deactivateAccount", ServerController, :deactivate_account
    post "/com.atproto.server.activateAccount", ServerController, :activate_account
    get "/com.atproto.server.checkAccountStatus", ServerController, :check_account_status
    post "/com.atproto.server.createAppPassword", ServerController, :create_app_password
    get "/com.atproto.server.listAppPasswords", ServerController, :list_app_passwords
    post "/com.atproto.server.revokeAppPassword", ServerController, :revoke_app_password

    post "/com.atproto.server.requestEmailConfirmation",
         ServerController,
         :request_email_confirmation

    post "/com.atproto.server.confirmEmail", ServerController, :confirm_email
    post "/com.atproto.server.requestEmailUpdate", ServerController, :request_email_update
    post "/com.atproto.server.updateEmail", ServerController, :update_email
    post "/com.atproto.server.requestPasswordReset", ServerController, :request_password_reset
    post "/com.atproto.server.resetPassword", ServerController, :reset_password
    post "/com.atproto.server.requestAccountDelete", ServerController, :request_account_delete
    post "/com.atproto.server.deleteAccount", ServerController, :delete_account
    post "/com.atproto.server.createInviteCode", ServerController, :create_invite_code
    get "/com.atproto.server.getAccountInviteCodes", ServerController, :get_account_invite_codes

    # com.atproto.identity
    get "/com.atproto.identity.resolveHandle", IdentityController, :resolve_handle
    get "/com.atproto.identity.resolveDid", IdentityController, :resolve_did
    get "/com.atproto.identity.resolveIdentity", IdentityController, :resolve_identity
    post "/com.atproto.identity.refreshIdentity", IdentityController, :refresh_identity
    post "/com.atproto.identity.updateHandle", IdentityController, :update_handle

    get "/com.atproto.identity.getRecommendedDidCredentials",
        IdentityController,
        :get_recommended_did_credentials

    post "/com.atproto.identity.requestPlcOperationSignature",
         IdentityController,
         :request_plc_operation_signature

    post "/com.atproto.identity.signPlcOperation", IdentityController, :sign_plc_operation
    post "/com.atproto.identity.submitPlcOperation", IdentityController, :submit_plc_operation

    # com.atproto.repo
    post "/com.atproto.repo.createRecord", RepoController, :create_record
    post "/com.atproto.repo.putRecord", RepoController, :put_record
    post "/com.atproto.repo.deleteRecord", RepoController, :delete_record
    post "/com.atproto.repo.applyWrites", RepoController, :apply_writes
    get "/com.atproto.repo.getRecord", RepoController, :get_record
    get "/com.atproto.repo.listRecords", RepoController, :list_records
    get "/com.atproto.repo.describeRepo", RepoController, :describe_repo
    post "/com.atproto.repo.uploadBlob", RepoController, :upload_blob
    get "/com.atproto.repo.listMissingBlobs", RepoController, :list_missing_blobs
    post "/com.atproto.repo.importRepo", RepoController, :import_repo

    # com.atproto.sync (the PDS's subset)
    get "/com.atproto.sync.getRepo", SyncController, :get_repo
    get "/com.atproto.sync.getRecord", SyncController, :get_record
    get "/com.atproto.sync.getBlocks", SyncController, :get_blocks
    get "/com.atproto.sync.getLatestCommit", SyncController, :get_latest_commit
    get "/com.atproto.sync.getRepoStatus", SyncController, :get_repo_status
    get "/com.atproto.sync.listRepos", SyncController, :list_repos
    get "/com.atproto.sync.getBlob", SyncController, :get_blob
    get "/com.atproto.sync.listBlobs", SyncController, :list_blobs

    # app.bsky exceptions served locally (DESIGN §11.1)
    get "/app.bsky.actor.getPreferences", PreferencesController, :get_preferences
    post "/app.bsky.actor.putPreferences", PreferencesController, :put_preferences

    # com.atproto.admin (subset); com.atproto.moderation.createReport is proxied to the mod service (DESIGN §17.2)
    get "/com.atproto.admin.getAccountInfo", AdminController, :get_account_info
    get "/com.atproto.admin.getAccountInfos", AdminController, :get_account_infos
    get "/com.atproto.admin.getSubjectStatus", AdminController, :get_subject_status
    post "/com.atproto.admin.updateSubjectStatus", AdminController, :update_subject_status
    post "/com.atproto.admin.updateAccountEmail", AdminController, :update_account_email
    post "/com.atproto.admin.updateAccountHandle", AdminController, :update_account_handle
    post "/com.atproto.admin.updateAccountPassword", AdminController, :update_account_password
    post "/com.atproto.admin.deleteAccount", AdminController, :delete_account
    post "/com.atproto.admin.sendEmail", AdminController, :send_email
    get "/com.atproto.admin.getInviteCodes", AdminController, :get_invite_codes
    post "/com.atproto.admin.disableInviteCodes", AdminController, :disable_invite_codes
    post "/com.atproto.admin.disableAccountInvites", AdminController, :disable_account_invites
    post "/com.atproto.admin.enableAccountInvites", AdminController, :enable_account_invites
  end

  # Spaces (DESIGN §12.5): the PDS plays all three roles — the writer's PDS,
  # the repo host and the space host — plus the simplespace management API.
  scope "/xrpc", AeroxWeb.PDS do
    pipe_through [:xrpc, :pds]

    # PDS role
    get "/com.atproto.space.getDelegationToken", SpaceController, :get_delegation_token
    post "/com.atproto.space.createRecord", SpaceController, :create_record
    post "/com.atproto.space.putRecord", SpaceController, :put_record
    post "/com.atproto.space.deleteRecord", SpaceController, :delete_record
    post "/com.atproto.space.applyWrites", SpaceController, :apply_writes
    get "/com.atproto.space.listSpaces", SpaceController, :list_spaces

    # repo-host role
    get "/com.atproto.space.getRecord", SpaceController, :get_record
    get "/com.atproto.space.listRecords", SpaceController, :list_records
    get "/com.atproto.space.getRepoState", SpaceController, :get_repo_state
    get "/com.atproto.space.listRepoOps", SpaceController, :list_repo_ops
    get "/com.atproto.space.getRepo", SpaceController, :get_repo
    get "/com.atproto.space.getBlob", SpaceController, :get_blob

    # space-host role
    post "/com.atproto.space.getSpaceCredential", SpaceController, :get_space_credential
    get "/com.atproto.space.getSpace", SpaceController, :get_space
    get "/com.atproto.space.listRepos", SpaceController, :list_repos
    post "/com.atproto.space.registerNotify", SpaceController, :register_notify
    post "/com.atproto.space.notifyWrite", SpaceController, :notify_write
    post "/com.atproto.space.notifySpaceDeleted", SpaceController, :notify_space_deleted

    # com.atproto.simplespace (the mandatory management handler)
    post "/com.atproto.simplespace.createSpace", SimplespaceController, :create_space
    post "/com.atproto.simplespace.updateSpace", SimplespaceController, :update_space
    post "/com.atproto.simplespace.deleteSpace", SimplespaceController, :delete_space
    get "/com.atproto.simplespace.getSpace", SimplespaceController, :get_space
    post "/com.atproto.simplespace.addMember", SimplespaceController, :add_member
    post "/com.atproto.simplespace.removeMember", SimplespaceController, :remove_member
    get "/com.atproto.simplespace.listMembers", SimplespaceController, :list_members
  end

  scope "/xrpc", AeroxWeb do
    pipe_through [:xrpc, :pds]
    get "/com.atproto.sync.subscribeRepos", Sockets.Firehose.Plug, Aerox.PDS.Sequencer.Source
  end

  # Everything else under /xrpc is proxied (DESIGN §11.1) or, with no target,
  # answered 501 MethodNotImplemented as xrpc-server does.
  scope "/xrpc", AeroxWeb.PDS do
    pipe_through [:xrpc, :pds]
    match :*, "/*method", ProxyController, :proxy
  end

  # The did:plc directory, route for route with did-method-plc's server.
  scope "/", AeroxWeb.PLC do
    pipe_through :plc

    get "/_health", PLCController, :health
    get "/export", PLCController, :export
    post "/admin/removeInvalidOps", PLCController, :remove_invalid_ops
    get "/:did", PLCController, :document, did: ~r/^did:plc:[a-z2-7]{24}$/
    get "/:did/data", PLCController, :data, did: ~r/^did:plc:[a-z2-7]{24}$/
    get "/:did/log", PLCController, :log, did: ~r/^did:plc:[a-z2-7]{24}$/
    get "/:did/log/audit", PLCController, :audit, did: ~r/^did:plc:[a-z2-7]{24}$/
    get "/:did/log/last", PLCController, :last, did: ~r/^did:plc:[a-z2-7]{24}$/
    post "/:did", PLCController, :submit, did: ~r/^did:plc:[a-z2-7]{24}$/
  end

  if Application.compile_env(:aerox, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AeroxWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
