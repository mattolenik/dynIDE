defmodule HerdrScene.Scene.Node do
  @moduledoc """
  A chrome node: role, text, props and theme token only. Never glyphs, colours
  or escape sequences; each client maps roles and tokens to its own look.
  `props` is open and is not policed by `HerdrScene.Scene.validate/1`.
  """

  @type rect :: HerdrScene.Scene.rect()
  @type t :: %__MODULE__{
          role: HerdrScene.Scene.role(),
          id: term,
          rect: rect | nil,
          text: binary | nil,
          token: HerdrScene.Scene.token() | nil,
          props: map,
          children: [t()]
        }

  @enforce_keys [:role]
  defstruct [:role, :id, :rect, :text, :token, props: %{}, children: []]

  @doc "Finds a descendant by a path of ids starting below `node`. `[]` is `node` itself."
  @spec find(t(), [term]) :: t() | nil
  def find(node, []), do: node

  def find(%__MODULE__{children: children}, [id | rest]) do
    case Enum.find(children, &(&1.id == id)) do
      nil -> nil
      child -> find(child, rest)
    end
  end
end
