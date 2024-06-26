defmodule Slivce.Stats do
  @derive Jason.Encoder
  defstruct current_streak: 0,
            max_streak: 0,
            lost: 0,
            guessed_at_attempt: nil,
            guess_distribution: %{
              "1" => 0,
              "2" => 0,
              "3" => 0,
              "4" => 0,
              "5" => 0,
              "6" => 0
            }

  @type t() :: %__MODULE__{
          current_streak: Integer.t(),
          max_streak: Integer.t(),
          lost: Integer.t(),
          guessed_at_attempt: Integer.t() | nil,
          guess_distribution: %{required(String.t()) => Integer.t()}
        }

  @spec new() :: t()
  def new() do
    %__MODULE__{}
  end
end
