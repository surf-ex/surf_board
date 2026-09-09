# :browser-tagged tests need a real Chrome session; run them via
# SURFBOARD_INTEGRATION=1 mix test integration_test, not the default
# `mix test`, so the unit suite never requires a browser to be installed.
ExUnit.configure(exclude: [browser: true])
ExUnit.start()
