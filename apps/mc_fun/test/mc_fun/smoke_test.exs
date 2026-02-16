defmodule McFun.SmokeTest do
  @moduledoc "Smoke tests requiring a live RCON connection. Run: mix test apps/mc_fun/test --only smoke"
  use ExUnit.Case

  @moduletag :smoke

  describe "RCON connectivity" do
    test "list command returns players online" do
      assert {:ok, response} = McFun.Rcon.command("list")
      assert response =~ "players online"
    end
  end

  describe "LogWatcher" do
    test "process is alive" do
      assert Process.whereis(McFun.LogWatcher) != nil
    end

    test "online_players returns a list" do
      players = McFun.LogWatcher.online_players()
      assert is_list(players)
    end
  end

  describe "EventStore round-trip" do
    test "push and list" do
      event = {:mc_event, :custom, %{test: true, timestamp: DateTime.utc_now()}}
      McFun.EventStore.push(event)
      events = McFun.EventStore.list()
      assert Enum.any?(events, fn e -> e == event end)
    end
  end

  describe "PubSub delivery" do
    test "subscribe and receive event" do
      McFun.Events.subscribe(:all)
      McFun.Events.dispatch(:custom, %{smoke_test: true})
      assert_receive {:mc_event, :custom, %{smoke_test: true}}, 1_000
    end
  end

  describe "parse_player_list/1" do
    test "parses standard response" do
      response = "There are 2 of a max of 20 players online: DonaldMahanahan, kurgenjlopp"
      assert McFun.LogWatcher.parse_player_list(response) == ["DonaldMahanahan", "kurgenjlopp"]
    end

    test "parses zero players" do
      response = "There are 0 of a max of 20 players online:"
      assert McFun.LogWatcher.parse_player_list(response) == []
    end

    test "parses single player" do
      response = "There are 1 of a max of 20 players online: DonaldMahanahan"
      assert McFun.LogWatcher.parse_player_list(response) == ["DonaldMahanahan"]
    end
  end

  describe "player data" do
    test "player_statuses returns map with health when players online" do
      players = McFun.LogWatcher.online_players()

      if players != [] do
        statuses = McFun.LogWatcher.player_statuses()
        assert is_map(statuses)

        player = hd(players)
        data = Map.get(statuses, player, %{})
        assert Map.has_key?(data, :health)
      end
    end
  end
end
