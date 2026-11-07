defmodule ActivityPub.Web.FederationEnabledTest do
  use ActivityPub.DataCase

  alias ActivityPub.Config

  # restores the setting, or removes it if it was not set: putting back a `nil` would leave federation in manual mode for the tests that run next
  setup do
    clear_config([:instance, :federating])
  end

  test "can disable federation entirely" do
    Config.put([:instance, :federating], false)

    assert false == Config.federating?()
  end

  test "can set federation to manual mode" do
    Config.put([:instance, :federating], nil)

    assert nil == Config.federating?()

    Config.put([:instance, :federating], :manual)

    assert nil == Config.federating?()
  end

  test "can enable federation" do
    Config.put([:instance, :federating], true)

    assert true == Config.federating?()
  end
end
