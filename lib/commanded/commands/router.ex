defmodule Commanded.Commands.Router do
  @moduledoc """
  Command routing macro to allow configuration of each command to its command handler.

  ## Example

  Define a router module which uses `Commanded.Commands.Router` and configures
  available commands to dispatch:

      defmodule BankRouter do
        use Commanded.Commands.Router

        dispatch OpenAccount,
          to: OpenAccountHandler,
          aggregate: BankAccount,
          identity: :account_number
      end

  The `to` option determines which module receives the command being dispatched.
  This command handler module must implement a `handle/2` function. It receives
  the aggregate's state and the command to execute. Usually the command handler
  module will forward the command to the aggregate.

  Once configured, you can either dispatch a command using the module by and
  specify the application:

      command = %OpenAccount{account_number: "ACC123", initial_balance: 1_000}

      :ok = BankRouter.dispatch(command, application: BankApp)

  Or, more simply you should include the router module in your application:

      defmodule BankApp do
        use Commanded.Application, otp_app: :my_app

        router MyApp.Router
      end

  Then dispatch commands using the app:

      command = %OpenAccount{account_number: "ACC123", initial_balance: 1_000}

      :ok = BankApp.dispatch(command)

  ## Dispatch command directly to an aggregate

  You can route a command directly to an aggregate, without requiring an
  intermediate command handler.

  ### Example

      defmodule BankRouter do
        use Commanded.Commands.Router

        dispatch OpenAccount, to: BankAccount, identity: :account_number
      end

  The aggregate must implement an `execute/2` function that receives the
  aggregate's state and the command being executed.

  ## Define aggregate identity

  You can define the identity field for an aggregate once using the `identify` macro.
  The configured identity will be used for all commands registered to the aggregate,
  unless overridden by a command registration.

  ### Example

      defmodule BankRouter do
        use Commanded.Commands.Router

        identify BankAccount,
          by: :account_number,
          prefix: "bank-account-"

        dispatch OpenAccount, to: BankAccount
      end

  An optional identity prefix can be used to distinguish between different
  aggregates that  would otherwise share the same identity. As an example you
  might have a `User` and a `UserPreferences` aggregate that you wish
  to share the same identity. In this scenario you should specify a `prefix`
  for each aggregate (e.g. "user-" and "user-preference-").

  The prefix is used as the stream identity when appending and reading the
  aggregate's events: "<identity_prefix><aggregate_uuid>". It can be a string or
  a zero arity function returning a string.

  ## Consistency

  You can choose the consistency guarantee when dispatching a command. The
  available options are:

    - `:eventual` (default) - don't block command dispatch while waiting for
      event handlers

        :ok = BankApp.dispatch(command)
        :ok = BankApp.dispatch(command, consistency: :eventual)

    - `:strong` - block command dispatch until all strongly
      consistent event handlers and process managers have successfully processed
      all events created by the command.

      Use this when you have event handlers that update read models you need to
      query immediately after dispatching the command.

        :ok = BankApp.dispatch(command, consistency: :strong)

    - Provide an explicit list of event handler and process manager modules (or
      their configured names), containing only those handlers you'd like to wait
      for. No other handlers will be awaited on, regardless of their own
      configured consistency setting.

      ```elixir
      :ok = BankApp.dispatch(command, consistency: [ExampleHandler, AnotherHandler])
      :ok = BankApp.dispatch(command, consistency: ["ExampleHandler", "AnotherHandler"])
      ```

      Note you cannot opt-in to strong consistency for a handler that has been
      configured as eventually consistent.

  ## Aggregate version

  You can optionally choose to include the aggregate's version as part of the
  dispatch result by setting `include_aggregate_version` true.

      {:ok, aggregate_version} = BankApp.dispatch(command, include_aggregate_version: true)

  This is useful when you need to wait for an event handler (e.g. a read model
  projection) to be up-to-date before continuing or querying its data.

  ## Execution results

  You can also choose to include the execution result as part of the dispatch result by
  setting `include_execution_result` true.

      {:ok, execution_result} = BankApp.dispatch(command, include_execution_result: true)

  Or by setting `include_execution_result` in your application config file:

      # config/config.exs
      config :commanded, include_execution_result: true

  Use this if you need to get information from the events produced by the aggregate
  but you don't want to wait for the events to be projected.

  ## Metadata

  You can associate metadata with all events created by the command.

  Supply a map containing key/value pairs comprising the metadata:

      :ok = BankApp.dispatch(command, metadata: %{"ip_address" => "127.0.0.1"})

  """

  @callback dispatch(struct, keyword()) ::
              :ok | {:ok, non_neg_integer()} | {:ok, struct} | {:error, term}

  defmacro __using__(opts) do
    quote do
      require Logger

      import unquote(__MODULE__)
      @before_compile unquote(__MODULE__)

      @application Keyword.get(unquote(opts), :application)
      @registered_commands []
      @registered_identities %{}
      @registered_middleware []

      @default [
        middleware: [
          Commanded.Middleware.ExtractAggregateIdentity,
          Commanded.Middleware.ConsistencyGuarantee
        ],
        consistency: get_env(:default_consistency, :eventual),
        include_aggregate_version: get_env(:include_aggregate_version, false),
        include_execution_result: get_env(:include_execution_result, false),
        dispatch_timeout: 5_000,
        lifespan: Commanded.Aggregates.DefaultLifespan,
        metadata: %{},
        retry_attempts: 10
      ]
    end
  end

  @doc """
  Include the given middleware module to be called before and after
  success or failure of each command dispatch

  The middleware module must implement the `Commanded.Middleware` behaviour.

  Middleware modules are executed in the order they are defined.

  ## Example

      defmodule BankingRouter do
        use Commanded.Commands.Router

        middleware CommandLogger
        middleware MyCommandValidator
        middleware AuthorizeCommand

        dispatch [OpenAccount,DepositMoney] to: BankAccount, identity: :account_number
      end
  """
  defmacro middleware(middleware_module) do
    quote do
      @registered_middleware @registered_middleware ++ [unquote(middleware_module)]
    end
  end

  @doc """
  Define an aggregate's identity

  You can define the identity field for an aggregate using the `identify` macro.
  The configured identity will be used for all commands registered to the
  aggregate, unless overridden by a command registration.

  ## Example

      defmodule BankRouter do
        use Commanded.Commands.Router

        identify BankAccount,
          by: :account_number,
          prefix: "bank-account-"
      end

  """
  defmacro identify(aggregate_module, opts) do
    quote location: :keep, bind_quoted: [aggregate_module: aggregate_module, opts: opts] do
      case Map.get(@registered_identities, aggregate_module) do
        nil ->
          by =
            case Keyword.get(opts, :by) do
              nil ->
                raise "#{inspect(aggregate_module)} aggregate identity is missing the `by` option"

              by when is_atom(by) ->
                by

              by when is_function(by, 1) ->
                by

              invalid ->
                raise "#{inspect(aggregate_module)} aggregate identity has an invalid `by` option: #{
                        inspect(invalid)
                      }"
            end

          prefix =
            case Keyword.get(opts, :prefix) do
              nil ->
                nil

              prefix when is_function(prefix, 0) ->
                prefix

              prefix when is_binary(prefix) ->
                prefix

              invalid ->
                raise "#{inspect(aggregate_module)} aggregate has an invalid identity prefix: #{
                        inspect(invalid)
                      }"
            end

          @registered_identities Map.put(@registered_identities, aggregate_module,
                                   by: by,
                                   prefix: prefix
                                 )

        config ->
          raise "#{inspect(aggregate_module)} aggregate has already been identified by: `#{
                  inspect(Keyword.get(config, :by))
                }`"
      end
    end
  end

  @doc """
  Configure the command, or list of commands, to be dispatched to the
  corresponding handler for a given aggregate.
  """
  defmacro dispatch(command_module_or_modules, opts) do
    opts = parse_opts(opts, [])

    command_module_or_modules
    |> List.wrap()
    |> Enum.map(fn command_module ->
      quote do
        register(unquote(command_module), unquote(opts))
      end
    end)
  end

  @register_params [
    :to,
    :function,
    :aggregate,
    :identity,
    :identity_prefix,
    :timeout,
    :lifespan,
    :consistency
  ]

  @doc false
  defmacro register(command_module,
             to: handler,
             function: function,
             aggregate: aggregate,
             identity: identity,
             identity_prefix: identity_prefix,
             timeout: timeout,
             lifespan: lifespan,
             consistency: consistency
           ) do
    quote location: :keep do
      if Enum.member?(@registered_commands, unquote(command_module)) do
        raise ArgumentError,
          message:
            "Command `#{inspect(unquote(command_module))}` has already been registered in router `#{
              inspect(__MODULE__)
            }`"
      end

      # sanity check the configured modules exist
      ensure_module_exists(unquote(aggregate))
      ensure_module_exists(unquote(command_module))
      ensure_module_exists(unquote(handler))

      case unquote(lifespan) do
        nil ->
          :ok

        module when is_atom(module) ->
          ensure_module_exists(unquote(lifespan))

          unless function_exported?(unquote(lifespan), :after_event, 1) do
            raise ArgumentError,
              message:
                "Aggregate lifespan `#{inspect(unquote(lifespan))}` does not define a callback function: `after_event/1`"
          end

          unless function_exported?(unquote(lifespan), :after_command, 1) do
            raise ArgumentError,
              message:
                "Aggregate lifespan `#{inspect(unquote(lifespan))}` does not define a callback function: `after_command/1`"
          end

          unless function_exported?(unquote(lifespan), :after_error, 1) do
            raise ArgumentError,
              message:
                "Aggregate lifespan `#{inspect(unquote(lifespan))}` does not define a callback function: `after_error/1`"
          end

        invalid ->
          raise ArgumentError,
            message:
              "Invalid `lifespan` configured for #{inspect(unquote(aggregate))}: " <>
                inspect(invalid)
      end

      unless function_exported?(unquote(handler), unquote(function), 2) do
        raise ArgumentError,
          message:
            "Command handler `#{inspect(unquote(handler))}` does not define a `#{
              unquote(function)
            }/2` function"
      end

      @registered_commands [unquote(command_module) | @registered_commands]

      def dispatch(command)
      def dispatch(%unquote(command_module){} = command), do: do_dispatch(command, [])

      def dispatch(command, timeout_or_opts)

      def dispatch(%unquote(command_module){} = command, :infinity),
        do: do_dispatch(command, timeout: :infinity)

      def dispatch(%unquote(command_module){} = command, timeout) when is_integer(timeout),
        do: do_dispatch(command, timeout: timeout)

      def dispatch(%unquote(command_module){} = command, opts),
        do: do_dispatch(command, opts)

      defp do_dispatch(%unquote(command_module){} = command, opts) do
        unless application = Keyword.get(opts, :application, @application) do
          raise ArgumentError, message: "no :application provided"
        end

        causation_id = Keyword.get(opts, :causation_id)
        correlation_id = Keyword.get(opts, :correlation_id) || UUID.uuid4()

        consistency =
          Keyword.get(opts, :consistency) || unquote(consistency) || @default[:consistency]

        metadata = Keyword.get(opts, :metadata) || @default[:metadata]
        timeout = Keyword.get(opts, :timeout) || unquote(timeout) || @default[:dispatch_timeout]

        include_aggregate_version =
          Keyword.get(opts, :include_aggregate_version) || @default[:include_aggregate_version]

        include_execution_result =
          Keyword.get(opts, :include_execution_result) || @default[:include_execution_result]

        lifespan = Keyword.get(opts, :lifespan) || unquote(lifespan) || @default[:lifespan]
        retry_attempts = Keyword.get(opts, :retry_attempts) || @default[:retry_attempts]

        {identity, identity_prefix} =
          case Map.get(@registered_identities, unquote(aggregate)) do
            nil ->
              {unquote(identity), unquote(identity_prefix)}

            config ->
              identity = Keyword.get(config, :by) || unquote(identity)
              prefix = Keyword.get(config, :prefix) || unquote(identity_prefix)

              {identity, prefix}
          end

        alias Commanded.Commands.Dispatcher
        alias Commanded.Commands.Dispatcher.Payload

        payload = %Payload{
          application: application,
          command: command,
          command_uuid: UUID.uuid4(),
          causation_id: causation_id,
          correlation_id: correlation_id,
          consistency: consistency,
          handler_module: unquote(handler),
          handler_function: unquote(function),
          aggregate_module: unquote(aggregate),
          identity: identity,
          identity_prefix: identity_prefix,
          include_aggregate_version: include_aggregate_version,
          include_execution_result: include_execution_result,
          timeout: timeout,
          lifespan: lifespan,
          metadata: metadata,
          middleware: @registered_middleware ++ @default[:middleware],
          retry_attempts: retry_attempts
        }

        Dispatcher.dispatch(payload)
      end
    end
  end

  defmacro __before_compile__(_env) do
    quote generated: true do
      @doc false
      def __registered_commands__, do: @registered_commands

      @doc """
      Dispatch the given command to the registered handler.

      Returns `:ok` on success, or `{:error, reason}` on failure.
      """
      @spec dispatch(command :: struct) ::
              :ok
              | {:ok, execution_result :: Commanded.Commands.ExecutionResult.t()}
              | {:ok, aggregate_version :: integer}
              | {:error, :unregistered_command}
              | {:error, :consistency_timeout}
              | {:error, reason :: term}
      def dispatch(command), do: unregistered_command(command)

      @doc """
      Dispatch the given command to the registered handler providing a timeout.

      - `timeout_or_opts` is either an integer timeout or a keyword list of
        options. The timeout must be an integer greater than zero which
        specifies how many milliseconds to allow the command to be handled, or
        the atom `:infinity` to wait indefinitely. The default timeout value is
        five seconds.

        Alternatively, an options keyword list can be provided, it supports the
        following options.

        Options:

          - `causation_id` - an optional UUID used to identify the cause of the
            command being dispatched.

          - `correlation_id` - an optional UUID used to correlate related
            commands/events together.

          - `consistency` - one of `:eventual` (default) or `:strong`. By
            setting the consistency to `:strong` a successful command dispatch
            will block until all strongly consistent event handlers and process
            managers have handled all events created by the command.

          - `timeout` - as described above.

          - `include_aggregate_version` - set to true to include the aggregate
            stream version in the success response: `{:ok, aggregate_version}`
            The default is false, to return just `:ok`.

          - `include_execution_result` - set to true to include more
            information about the dispatch, like the aggregate name, uuid, and
            the produced events. Overrides `include_aggregate_version`. The
            default is false to return `:ok`. See
            `Commanded.Commands.ExecutionResult`.

          - `metadata` - an optional map containing key/value pairs comprising
            the metadata to be associated with all events created by the
            command.

      Returns `:ok` on success, unless `:include_aggregate_version` or
      `:include_execution_result` is enabled, where it respectively returns
      `{:ok, aggregate_version}` or `{:ok, %ExecutionResult{..}}`. Returns
      `{:error, reason}` on failure.
      """
      @spec dispatch(command :: struct, timeout_or_opts :: integer | :infinity | keyword()) ::
              :ok
              | {:ok, execution_result :: Commanded.Commands.ExecutionResult.t()}
              | {:ok, aggregate_version :: integer}
              | {:error, :unregistered_command}
              | {:error, :consistency_timeout}
              | {:error, reason :: term}
      def dispatch(command, _opts), do: unregistered_command(command)

      defp unregistered_command(command) do
        _ =
          Logger.error(fn ->
            "attempted to dispatch an unregistered command: " <> inspect(command)
          end)

        {:error, :unregistered_command}
      end
    end
  end

  @doc false
  def ensure_module_exists(module) do
    unless Code.ensure_compiled?(module) do
      raise "module `#{inspect(module)}` does not exist, perhaps you forgot to `alias` the namespace"
    end
  end

  @doc false
  def get_env(name, default \\ nil), do: Application.get_env(:commanded, name, default)

  defp parse_opts([{:to, aggregate_or_handler} | opts], result) do
    case Keyword.pop(opts, :aggregate) do
      {nil, opts} ->
        aggregate = aggregate_or_handler
        parse_opts(opts, [function: :execute, to: aggregate, aggregate: aggregate] ++ result)

      {aggregate, opts} ->
        handler = aggregate_or_handler
        parse_opts(opts, [function: :handle, to: handler, aggregate: aggregate] ++ result)
    end
  end

  defp parse_opts([{param, value} | opts], result) when param in @register_params do
    parse_opts(opts, [{param, value} | result])
  end

  defp parse_opts([{param, _value} | _opts], _result) do
    raise """
    unexpected dispatch parameter "#{param}"
    available params are: #{@register_params |> Enum.map(&to_string/1) |> Enum.join(", ")}
    """
  end

  defp parse_opts([], result) do
    Enum.map(@register_params, fn key -> {key, Keyword.get(result, key)} end)
  end
end
