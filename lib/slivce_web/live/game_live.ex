defmodule SlivceWeb.GameLive do
  use SlivceWeb, :live_view
  alias Slivce.{GameEngine, WordServer, Stats, Settings, Game}
  alias Slivce.Utils.TimeTZ
  import SlivceWeb.GameComponent
  require Logger

  @session_key "app:session"
  @session_version 1

  @impl true
  def mount(_params, _session, socket) do
    {game, stats, settings} =
      case get_connect_params(socket) do
        %{"restore" => nil} ->
          init_new_game()

        %{"restore" => data} ->
          # Wrap in try block in the case when the localStorage schema has been changed.
          try do
            game = game_from_json_string(data)
            stats = stats_from_json_string(data)
            settings = settings_from_json_string(data)

            if game.played_timestamp && game.played_timestamp < TimeTZ.year_day_now() do
              {game, stats, _settings} = init_new_game()
              {game, stats, settings}
            else
              {game, stats, settings}
            end
          rescue
            error ->
              Logger.error("mount: restore rescure, #{inspect(error)}")
              init_new_game()
          end

        nil ->
          init_new_game()
      end

    {:ok,
     assign(socket,
       game: game,
       stats: stats,
       revealing?: true,
       message: Enum.at(game.result, 1) |> compound_game_over_message(),
       valid_guess?: true,
       settings: settings,
       show_help_modal?: not game.over? and (game.current_word_index == 0 and length(game.guesses) == 0),
       show_info_modal?: game.over?
     )}
  end

  defp init_new_game(), do: {new_game(0), Stats.new(), Settings.new()}

  @impl true
  def render(assigns) do
    ~H"""
    <div class={"#{if(@settings.theme == :dark, do: "dark", else: "")}"}>
      <div class="dark:bg-gray-900">
        <.help_modal open?={@show_help_modal?} />
        <.info_modal game={@game} stats={@stats} show_countdown?={@game.over?} open?={@show_info_modal?} />
        <.settings_modal checked?={@settings.theme == :dark} />

        <div id="game" phx-hook="Session" class="flex flex-col justify-between h-svh">
          <.site_header />

          <div>
            <div class="flex flex-col items-center">
              <div class="relative min-w-48 z-10">
                <%= if @message do %>
                  <div class="absolute h-full w-full flex text-center items-center justify-center -my-2">
                    <div class="mx-2">
                      <.alert message={@message} />
                    </div>
                  </div>
                <% end %>
              </div>

              <div class="">
                <.grid
                  past_guesses={Enum.reverse(@game.guesses)}
                  valid_guess?={@valid_guess?}
                  revealing?={length(@game.guesses) > 0 && @revealing?}
                  game_over?={@game.over?}
                />
              </div>
            </div>
            <div class="mx-2 mt-8 sm:mx-4 sm:mt-12">
              <.keyboard letter_map={GameEngine.letter_map(@game)} />
            </div>
          </div>

          <.site_footer />
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_theme", _params, %{assigns: %{settings: settings}} = socket) do
    theme =
      case settings.theme do
        :dark -> :light
        :light -> :dark
      end

    settings = %{settings | theme: theme}
    {:noreply, socket |> assign(settings: settings) |> store_session()}
  end

  @impl true
  def handle_event("submit", _params, %{assigns: %{game: %Game{over?: true}}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("submit", %{"guess" => guess}, socket) do
    case guess |> String.graphemes() |> length() do
      n when n < 5 ->
        {:noreply, socket |> put_message("Недостатньо літер") |> assign(valid_guess?: false)}

      _ ->
        if WordServer.valid_guess?(guess) do
          game =
            GameEngine.resolve(socket.assigns.game, guess)
            |> Map.put(:played_timestamp, TimeTZ.year_day_now())

          stats = update_stats(game, socket.assigns.stats)

          {:noreply,
           socket
           |> push_event("keyboard:reset", %{})
           |> assign(game: game, stats: stats, revealing?: true, valid_guess?: true)
           |> maybe_put_game_over_message(game)
           |> maybe_show_info_dialog(game)
           |> store_session()}
        else
          {:noreply, socket |> put_message("Не знайдено в словнику") |> assign(valid_guess?: false)}
        end
    end
  end

  @impl true
  def handle_event("game:next", _, %{assigns: %{game: game}} = socket) do
    new_index = rem(game.current_word_index + 1, get_words_of_the_day_number())
    next_game(new_index, socket)
  end

  @impl true
  def handle_event("game:reset", _, socket) do
    {_, socket} = next_game(0, socket)
    game = %{socket.assigns.game | played_timestamp: nil}
    {:noreply, assign(socket, game: game, stats: Stats.new())}
  end

  defp next_game(new_index, socket) do
    game = new_game(new_index)

    socket =
      socket
      |> push_event("keyboard:reset", %{})
      |> assign(game: game, show_info_modal?: false, message: nil)
      |> store_session()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:clear_message, socket),
    do: {:noreply, assign(socket, message: nil, revealing?: false)}

  @impl true
  def handle_info(:show_info_modal, socket) do
    {:noreply, assign(socket, show_info_modal?: true)}
  end

  defp put_message(socket, message, temporary: temporary) do
    if temporary, do: Process.send_after(self(), :clear_message, 2000)
    assign(socket, message: message)
  end

  defp put_message(socket, message), do: put_message(socket, message, temporary: true)

  defp maybe_show_info_dialog(socket, %{over?: false}) do
    socket
  end

  defp maybe_show_info_dialog(socket, %{over?: true}) do
    Process.send_after(self(), :show_info_modal, 2000)
    socket
  end

  defp maybe_put_game_over_message(socket, %{over?: false}), do: socket

  defp maybe_put_game_over_message(socket, %{result: [:lost, actual_word]}),
    do: put_message(socket, compound_game_over_message(actual_word), temporary: false)

  defp maybe_put_game_over_message(socket, %{} = game) do
    message =
      case GameEngine.guesses_left(game) do
        0 -> "Зле!"
        1 -> "Задовільно!"
        2 -> "Нормально!"
        3 -> "Чудово!"
        4 -> "Вражаюче!"
        _ -> "Видатно!"
      end

    put_message(socket, message)
  end

  defp compound_game_over_message(actual_word) when is_binary(actual_word), do: "Слово було #{actual_word}"
  defp compound_game_over_message(_actual_word), do: nil

  defp store_session(%{assigns: assigns} = socket) do
    data =
      assigns
      |> Map.take(~w(game stats settings)a)
      |> Map.put_new(:version, @session_version)
      |> Jason.encode!()

    push_event(socket, "session:store", %{key: @session_key, data: data})
  end

  defp new_game(current_word_index), do: GameEngine.new(current_word_index)

  defp update_stats(%{result: [:playing]}, stats), do: stats

  defp update_stats(%{result: [:lost, _actual_word]}, stats) do
    %{stats | lost: stats.lost + 1, current_streak: 0, max_streak: max(0, stats.max_streak)}
  end

  defp update_stats(game, stats) do
    {guessed_at_attempt, current_streak} =
      if GameEngine.won?(game) do
        {abs(GameEngine.guesses_left(game) - 6), stats.current_streak + 1}
      else
        {stats.guessed_at_attempt, 0}
      end

    max_streak = max(current_streak, stats.max_streak)
    key = Integer.to_string(guessed_at_attempt)
    value = stats.guess_distribution[key] + 1

    %{
      stats
      | guess_distribution: Map.put(stats.guess_distribution, key, value),
        guessed_at_attempt: guessed_at_attempt,
        current_streak: current_streak,
        max_streak: max_streak
    }
  end

  defp game_from_json_string(data) do
    %{game: game_data} = Jason.decode!(data, keys: :atoms)
    game = struct!(Slivce.Game, game_data)

    result =
      case game.result do
        [first | rest] -> [String.to_existing_atom(first) | rest]
      end

    guesses =
      Enum.map(game.guesses, fn guess ->
        Enum.map(guess, fn guess_info ->
          %{guess_info | state: String.to_existing_atom(guess_info.state)}
        end)
      end)

    %{game | result: result, guesses: guesses}
  end

  defp stats_from_json_string(data) do
    %{stats: stats_data} = Jason.decode!(data, keys: :atoms)

    guess_distribution =
      Map.new(stats_data.guess_distribution, fn {k, v} -> {Atom.to_string(k), v} end)

    struct!(Stats, %{stats_data | guess_distribution: guess_distribution})
  end

  defp settings_from_json_string(data) do
    %{settings: settings_data} = Jason.decode!(data, keys: :atoms)
    settings = struct!(Settings, settings_data)
    %{settings | theme: String.to_existing_atom(settings.theme)}
  end

  defp get_words_of_the_day_number(), do: Slivce.config([:game, :words_of_the_day_number])
end
