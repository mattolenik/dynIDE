defmodule DynideScene.SceneGraphicTest do
  use ExUnit.Case, async: true

  alias DynideScene.Protocol
  alias DynideScene.Scene
  alias DynideScene.Scene.{Graphic, Node, Pane}

  defp g(over \\ %{}) do
    Map.merge(
      %{
        image: {7, 42},
        placement: 3,
        x: 0,
        y: -2,
        cols: 4,
        rows: 2,
        x_off: 0,
        y_off: 0,
        src: {0, 0, 0, 0},
        px: {0, 0},
        z: 0,
        size: {2, 2},
        format: :rgb,
        bytes: 12
      },
      over
    )
  end

  defp img(over \\ %{}),
    do: Map.merge(%{format: :rgba, width: 2, height: 1, bytes: 8, data: <<0::64>>}, over)

  test "a valid placement passes; x and y may be negative" do
    assert Graphic.validate(g()) == :ok
    assert Graphic.validate(g(%{x: -3, z: -5})) == :ok
  end

  test "each bad key is named" do
    for {k, v} <- [
          image: 7,
          image: {0, 1},
          placement: 0,
          x: 1.5,
          cols: 0,
          rows: 0,
          x_off: -1,
          src: {0, 0, 0},
          px: {-1, 0},
          z: nil,
          size: {0, 2},
          format: :jpeg,
          bytes: -1
        ] do
      assert {:error, msg} = Graphic.validate(g(%{k => v}))
      assert msg =~ Atom.to_string(k)
    end

    assert {:error, msg} = Graphic.validate(Map.delete(g(), :format))
    assert msg =~ "format"
    assert {:error, _} = Graphic.validate(:nope)
  end

  test "formats" do
    assert Graphic.formats() == [:rgb, :rgba, :png]
  end

  test "image payloads" do
    assert Graphic.validate_image(img()) == :ok
    assert Graphic.validate_image(img(%{data: nil})) == :ok
    assert {:error, _} = Graphic.validate_image(img(%{data: 1}))
    assert {:error, _} = Graphic.validate_image(img(%{format: :gif}))
    assert {:error, _} = Graphic.validate_image(img(%{width: 0}))
  end

  test "scene validation reports the graphic path" do
    pane = %Pane{
      id: 1,
      rect: %{x: 0, y: 0, w: 10, h: 5},
      rows: {:ref, 1, 0},
      graphics: [g(%{cols: 0})]
    }

    scene = %Scene{
      size: %{cols: 10, rows: 5},
      panes: [pane],
      chrome: %Node{role: :root},
      focus: %{pane: 1, chrome: nil}
    }

    assert {:error, msgs} = Scene.validate(scene)
    assert Enum.any?(msgs, &String.starts_with?(&1, "panes[0].graphics[0]"))
    assert Scene.validate(%{scene | panes: [%{pane | graphics: [g()]}]}) == :ok
  end

  test "attach reply may carry an images MFA" do
    assert Protocol.validate_attach_reply(
             {:ok, self(), %{rows: {M, :f, []}, images: {M, :g, []}}}
           ) ==
             :ok

    assert {:error, _} =
             Protocol.validate_attach_reply({:ok, self(), %{rows: {M, :f, []}, images: :x}})
  end

  test "image messages" do
    assert Protocol.validate_server_msg({:image, 1, {7, 42}, img()}) == :ok
    assert Protocol.validate_server_msg({:image, 1, {7, 42}, img(%{data: nil})}) == :ok
    assert {:error, _} = Protocol.validate_server_msg({:image, 1, {7, 42}, img(%{width: -1})})
    assert {:error, _} = Protocol.validate_server_msg({:image, 0, {7, 42}, img()})
    assert {:error, _} = Protocol.validate_server_msg({:image, 1, 7, img()})
  end
end
