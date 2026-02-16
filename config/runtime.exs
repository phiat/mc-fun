import Config

# Load .env file — Dotenvy.source! returns a merged map, doesn't set system env
env =
  if config_env() in [:dev, :test] do
    Dotenvy.source!([".env", System.get_env()])
  else
    System.get_env()
  end

# RCON configuration
config :mc_fun, :rcon,
  host: Map.get(env, "RCON_HOST", "localhost"),
  port: String.to_integer(Map.get(env, "RCON_PORT", "25575")),
  password: Map.get(env, "RCON_PASSWORD", ""),
  pool_size: String.to_integer(Map.get(env, "RCON_POOL_SIZE", "2"))

# Minecraft server (for mineflayer)
config :mc_fun, :minecraft,
  host: Map.get(env, "MC_HOST", "localhost"),
  port: String.to_integer(Map.get(env, "MC_PORT", "25565"))

# Groq API
config :mc_fun, :groq,
  api_key: Map.get(env, "GROQ_API_KEY", ""),
  model: Map.get(env, "GROQ_MODEL", "openai/gpt-oss-20b")

# ChatBot tuning
config :mc_fun, :chat_bot,
  default_personality:
    Map.get(
      env,
      "CHATBOT_DEFAULT_PERSONALITY",
      "You are a friendly Minecraft bot. Keep responses to 1-2 sentences. No markdown."
    ),
  heartbeat_behavior_ms:
    String.to_integer(Map.get(env, "CHATBOT_HEARTBEAT_BEHAVIOR_MS", "15000")),
  heartbeat_idle_ms: String.to_integer(Map.get(env, "CHATBOT_HEARTBEAT_IDLE_MS", "120000")),
  heartbeat_cooldown_ms:
    String.to_integer(Map.get(env, "CHATBOT_HEARTBEAT_COOLDOWN_MS", "10000")),
  followup_max_tokens: String.to_integer(Map.get(env, "CHATBOT_FOLLOWUP_MAX_TOKENS", "256")),
  heartbeat_max_tokens: String.to_integer(Map.get(env, "CHATBOT_HEARTBEAT_MAX_TOKENS", "128")),
  max_response_tokens: String.to_integer(Map.get(env, "CHATBOT_MAX_RESPONSE_TOKENS", "1024"))

# Bot-to-bot chat coordinator
config :mc_fun, :bot_chat,
  enabled: Map.get(env, "BOT_CHAT_ENABLED", "true") == "true",
  proximity: String.to_integer(Map.get(env, "BOT_CHAT_PROXIMITY", "32")),
  max_exchanges: String.to_integer(Map.get(env, "BOT_CHAT_MAX_EXCHANGES", "3")),
  cooldown_ms: String.to_integer(Map.get(env, "BOT_CHAT_COOLDOWN_MS", "60000")),
  response_chance: String.to_float(Map.get(env, "BOT_CHAT_RESPONSE_CHANCE", "0.7")),
  min_delay_ms: String.to_integer(Map.get(env, "BOT_CHAT_MIN_DELAY_MS", "2000")),
  max_delay_ms: String.to_integer(Map.get(env, "BOT_CHAT_MAX_DELAY_MS", "5000")),
  topic_interval_ms: String.to_integer(Map.get(env, "BOT_CHAT_TOPIC_INTERVAL_MS", "300000")),
  topic_injection_enabled: Map.get(env, "BOT_CHAT_TOPIC_INJECTION", "false") == "true"

# Log watcher
config :mc_fun, :log_watcher,
  log_path: Map.get(env, "MC_LOG_PATH"),
  poll_interval: String.to_integer(Map.get(env, "LOG_POLL_INTERVAL_MS", "2000"))

# Webhook security (optional)
config :mc_fun, :webhook_secret, Map.get(env, "WEBHOOK_SECRET")

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
#     PHX_SERVER=true bin/mc_fun start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if Map.get(env, "PHX_SERVER") do
  config :mc_fun, McFunWeb.Endpoint, server: true
end

config :mc_fun, McFunWeb.Endpoint, http: [port: String.to_integer(Map.get(env, "PORT", "4000"))]

if config_env() == :prod do
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

  config :mc_fun, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :mc_fun, McFunWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :mc_fun, McFunWeb.Endpoint,
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
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :mc_fun, McFunWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
