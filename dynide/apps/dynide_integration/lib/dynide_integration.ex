defmodule DynideIntegration do
  @moduledoc """
  Test-only umbrella app hosting cross-app tests: the architecture test (no
  cross-app module references in compiled beams) and scripted stand-ins for
  the manual exit checks, running `dynide_server` and `dynide_term` together
  against the fake kernels. The only app allowed to depend on both.
  """
end
