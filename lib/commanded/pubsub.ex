defmodule Commanded.PubSub do
  @moduledoc """
  Pub/sub behaviour for use by Commanded to subcribe to and broadcast messages.
  """

  @type application :: module
  @type pubsub :: module

  @doc """
  Return an optional supervisor spec for pub/sub.
  """
  @callback child_spec(pubsub, config :: Keyword.t()) :: [:supervisor.child_spec()]

  @doc """
  Subscribes the caller to the PubSub adapter's topic.
  """
  @callback subscribe(pubsub, topic :: String.t()) :: :ok | {:error, term}

  @doc """
  Broadcasts message on given topic.

    * `topic` - The topic to broadcast to, ie: `"users:123"`
    * `message` - The payload of the broadcast

  """
  @callback broadcast(pubsub, topic :: String.t(), message :: term) :: :ok | {:error, term}

  @doc """
  Track the current process under the given `topic`, uniquely identified by
  `key`.
  """
  @callback track(pubsub, topic :: String.t(), key :: term) :: :ok | {:error, term}

  @doc """
  List tracked PIDs for a given topic.
  """
  @callback list(pubsub, topic :: String.t()) :: [{term, pid}]

  @doc false
  def subscribe(application, topic) do
    application.__pubsub_adapter__().subscribe(topic)
  end

  @doc false
  def broadcast(application, topic, message) do
    application.__pubsub_adapter__().broadcast(topic, message)
  end

  @doc """
  Get the configured pub/sub adapter.

  Defaults to a local pub/sub, restricted to running on a single node.
  """
  @spec pubsub_provider(application, config :: Keyword.t()) :: {module(), Keyword.t()}
  def pubsub_provider(application, config) do
    case Keyword.get(config, :pubsub, :local) do
      :local ->
        {Commanded.PubSub.LocalPubSub, []}

      provider when is_atom(provider) ->
        {provider, []}

      config ->
        if Keyword.keyword?(config) do
          case Keyword.get(config, :phoenix_pubsub) do
            nil ->
              raise ArgumentError,
                    "invalid Phoenix pubsub configuration #{inspect(config)} for application " <>
                      inspect(application)

            phoenix_pubsub ->
              {Commanded.PubSub.PhoenixPubSub, phoenix_pubsub}
          end
        else
          raise ArgumentError,
                "invalid pubsub configured for application " <>
                  inspect(application) <> " as: " <> inspect(config)
        end
    end
  end
end
