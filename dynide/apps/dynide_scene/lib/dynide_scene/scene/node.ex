defmodule DynideScene.Scene.Node do
  @moduledoc """
  A chrome node: role, text, props and theme token only. Never glyphs, colours
  or escape sequences; each client maps roles and tokens to its own look.
  `props` is open: `DynideScene.Scene.validate/1` checks only the role's
  required props (`DynideScene.Chrome.required_props/1`) and accepts extras.
  """

  @type rect :: DynideScene.Scene.rect()
  @type t :: %__MODULE__{
          role: DynideScene.Scene.role(),
          id: term,
          rect: rect | nil,
          text: binary | nil,
          token: DynideScene.Scene.token() | nil,
          props: map,
          children: [t()]
        }

  @enforce_keys [:role]
  defstruct [:role, :id, :rect, :text, :token, props: %{}, children: []]

  @doc "Finds a descendant by a path of ids starting below `node`. `[]` is `node` itself."
  @spec find(t(), [term]) :: t() | nil
  def find(node, []), do: node

  def find(%__MODULE__{children: children}, [id | rest]) when is_list(children) do
    case Enum.find(children, &match?(%__MODULE__{id: ^id}, &1)) do
      nil -> nil
      child -> find(child, rest)
    end
  end

  def find(_, _), do: nil
end
