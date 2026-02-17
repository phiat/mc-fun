defmodule Mix.Tasks.Mc.Chatbot do
  @moduledoc """
  Spawn an LLM-powered chat bot: mix mc.chatbot [name] [--personality "..."]

  The bot joins the server, listens to chat, and responds via Groq LLM.
  """
  @shortdoc "Spawn an LLM chat bot"
  use Mix.Task

  @personalities %{
    "guard" => """
    You are a gruff medieval guard watching over the castle. You speak in a formal,
    suspicious tone. You question visitors about their business. Keep responses to 1-2 sentences.
    No markdown formatting. Plain text only.
    """,
    "merchant" => """
    You are a traveling merchant in Minecraft. You're always looking to trade and make deals.
    You speak enthusiastically about rare items and treasures. Keep responses to 1-2 sentences.
    No markdown formatting. Plain text only.
    """,
    "pirate" => """
    You are a pirate captain who somehow ended up in Minecraft. You speak with pirate slang
    and are always looking for treasure. Yarr! Keep responses to 1-2 sentences.
    No markdown formatting. Plain text only.
    """,
    "wizard" => """
    You are an ancient wizard who speaks in riddles and mysterious ways. You know much about
    enchantments and potions. Keep responses to 1-2 sentences. No markdown formatting. Plain text only.
    """
  }

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [personality: :string])
    name = List.first(positional, "ChatBot")
    personality = get_personality(opts)

    Mix.Task.run("app.start")

    # Dynamic calls — BotSupervisor and ChatBot live in bot_farmer, not available at compile time
    case apply(McFun.BotSupervisor, :spawn_bot, [name]) do
      {:ok, _pid} ->
        Mix.shell().info("Bot #{name} spawned, waiting for it to join...")
        Process.sleep(2_000)

        {:ok, _} =
          DynamicSupervisor.start_child(
            McFun.BotSupervisor,
            {McFun.ChatBot, bot_name: name, personality: personality}
          )

        Mix.shell().info("ChatBot #{name} is now listening for chat. Press Ctrl+C to stop.")
        Mix.shell().info("Personality: #{String.slice(personality, 0..60)}...")
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp get_personality(opts) do
    case Keyword.get(opts, :personality) do
      nil -> Map.get(@personalities, "guard", Map.values(@personalities) |> List.first())
      key when is_binary(key) -> Map.get(@personalities, key, key)
    end
  end
end
