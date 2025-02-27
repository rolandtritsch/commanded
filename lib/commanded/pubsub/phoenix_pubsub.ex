if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Commanded.PubSub.PhoenixPubSub do
    @moduledoc """
    Pub/sub adapter using Phoenix's distributed pub/sub and presence platform.

    To use Phoenix pub/sub you must add it as a dependency in your project's
    `mix.exs` file:

        defp deps do
          [
            {:phoenix_pubsub, "~> 1.0"}
          ]
        end

    Fetch mix deps and configure the pubsub settings in your environment config
    file:

        # `config/config.exs`
        config :commanded, pubsub: [
          phoenix_pubsub: [
            adapter: Phoenix.PubSub.PG2,
            pool_size: 1
          ]
        ]

    Specify the Phoenix pub/sub adapter you wish to use from:

      * `Phoenix.PubSub.PG2` - uses Distributed Elixir, directly exchanging
        notifications between servers

      * `Phoenix.PubSub.Redis` - uses Redis to exchange data between servers

    """

    @behaviour Commanded.PubSub

    defmodule Tracker do
      @moduledoc false

      @behaviour Phoenix.Tracker

      def start_link(opts) do
        opts = Keyword.merge([name: __MODULE__], opts)
        Phoenix.Tracker.start_link(__MODULE__, opts, opts)
      end

      def init(opts) do
        server = Keyword.fetch!(opts, :pubsub_server)
        {:ok, %{pubsub_server: server, node_name: Phoenix.PubSub.node_name(server)}}
      end

      def handle_diff(_diff, state) do
        {:ok, state}
      end
    end

    @doc """
    Start the configured Phoenix pub/sub adapter and a presence tracker.
    """
    @spec child_spec() :: [:supervisor.child_spec()]
    @impl Commanded.PubSub
    def child_spec do
      phoenix_pubsub_config =
        Application.get_env(:commanded, :pubsub)
        |> Keyword.get(:phoenix_pubsub)
        |> Keyword.put(:name, __MODULE__)

      {adapter, phoenix_pubsub_config} = Keyword.pop(phoenix_pubsub_config, :adapter)
      phoenix_pubsub_config = parse_config(phoenix_pubsub_config)

      [
        %{
          id: adapter,
          start: {adapter, :start_link, [__MODULE__, phoenix_pubsub_config]},
          type: :supervisor
        },
        %{
          id: Tracker,
          start: {Tracker, :start_link, [[pubsub_server: __MODULE__]]},
          type: :supervisor
        }
      ]
    end

    @doc """
    Subscribes the caller to the topic.
    """
    @spec subscribe(String.t()) :: :ok | {:error, term}
    @impl Commanded.PubSub
    def subscribe(topic) when is_binary(topic) do
      Phoenix.PubSub.subscribe(__MODULE__, topic)
    end

    @doc """
    Broadcasts message on given topic.
    """
    @spec broadcast(String.t(), term) :: :ok | {:error, term}
    @impl Commanded.PubSub
    def broadcast(topic, message) when is_binary(topic) do
      Phoenix.PubSub.broadcast(__MODULE__, topic, message)
    end

    @doc """
    Track the current process under the given `topic`, uniquely identified by
    `key`.
    """
    @spec track(String.t(), term) :: :ok
    @impl Commanded.PubSub
    def track(topic, key) when is_binary(topic) do
      case Phoenix.Tracker.track(Tracker, self(), topic, key, %{pid: self()}) do
        {:ok, _ref} -> :ok
        {:error, {:already_tracked, _pid, _topic, _key}} -> :ok
        reply -> reply
      end
    end

    @doc """
    List tracked terms and associated PIDs for a given topic.
    """
    @spec list(String.t()) :: [{term, pid}]
    @impl Commanded.PubSub
    def list(topic) when is_binary(topic) do
      Phoenix.Tracker.list(Tracker, topic) |> Enum.map(fn {key, %{pid: pid}} -> {key, pid} end)
    end

    defp parse_config(config) do
      Enum.map(config, fn
        {key, {:system, env}} when key in [:port, :pool_size] ->
          {key, env |> System.get_env() |> String.to_integer()}

        {key, {:system, env}} ->
          {key, System.get_env(env)}

        pair ->
          pair
      end)
    end
  end
end
