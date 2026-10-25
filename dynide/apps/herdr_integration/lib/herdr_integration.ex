defmodule HerdrIntegration do
  @moduledoc """
  Test-only umbrella app hosting cross-app tests: the architecture test (no
  cross-app module references in compiled beams) and scripted stand-ins for
  the manual exit checks, running `herdr_server` and `herdr_term` together
  against the fake kernels. The only app allowed to depend on both.
  """
end
