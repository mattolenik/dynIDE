import Config

# Handoff (M5): a VM under herdr_broker (HERDR_BROKER_SOCK set) may be a warm standby.
# Its reload pipeline must not watch and compile beside the primary's, so herdr_server
# starts it (HerdrReload.Application.start_deferred/0) once this VM is the primary.
if System.get_env("HERDR_BROKER_SOCK") not in [nil, ""],
  do: config(:herdr_reload, HerdrReload, defer: true)

# M7: run the changed module's tests before each reload (adds seconds per save).
# `herdr-live test-on-save on|off` flips it at runtime.
if System.get_env("HERDR_LIVE_TEST_ON_SAVE") == "1" do
  config :herdr_reload, HerdrReload, test_on_save: :gate
end
