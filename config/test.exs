use Mix.Config

alias Commanded.EventStore.Adapters.InMemory
alias Commanded.Serialization.JsonSerializer

config :logger, :console, level: :warn, format: "[$level] $message\n"

config :ex_unit,
  capture_log: true,
  assert_receive_timeout: 1_000

config :commanded,
  assert_receive_event_timeout: 100,
  refute_receive_event_timeout: 100,
  dispatch_consistency_timeout: 100

default_app_config = [
  event_store: [adapter: InMemory, serializer: JsonSerializer],
  pubsub: :local,
  registry: :local
]

config :commanded, Commanded.Commands.ConsistencyApp, default_app_config
config :commanded, Commanded.DefaultApp, default_app_config
config :commanded, Commanded.Event.Upcast.ProcessManager.Application, default_app_config
config :commanded, Commanded.ProcessManagers.ErrorApp, default_app_config
config :commanded, Commanded.ProcessManagers.ExampleApp, default_app_config
config :commanded, Commanded.ProcessManagers.ResumeApp, default_app_config
config :commanded, Commanded.ProcessManagers.TodoApp, default_app_config
config :commanded, Commanded.TestApplication, default_app_config
