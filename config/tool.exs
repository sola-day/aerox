import Config

# MIX_ENV=tool (STRUCTURE §5): the reference-PDS interop tasks. Same databases
# and roles as dev, no web server, no code reloader, quiet logs.
import_config "dev.exs"

config :aerox, AeroxWeb.Endpoint, server: false, code_reloader: false
config :aerox, dev_routes: false
config :logger, level: :info
