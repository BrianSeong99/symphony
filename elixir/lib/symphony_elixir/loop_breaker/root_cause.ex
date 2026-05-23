defmodule SymphonyElixir.LoopBreaker.RootCause do
  @moduledoc """
  Classifies why the loop breaker stopped an issue.
  """

  @type trigger ::
          :repeated_failure_signature
          | :phase_validation_attempts_exhausted
          | :validation_spec_contradiction
          | atom()

  @type root_cause ::
          :deterministic_validation_failure
          | :validation_phase_exhausted
          | :spec_validation_contradiction
          | :unknown_loop_breaker_trigger

  @spec classify(trigger(), [map()]) :: root_cause()
  def classify(:validation_spec_contradiction, _evidence), do: :spec_validation_contradiction

  def classify(:repeated_failure_signature, _evidence), do: :deterministic_validation_failure

  def classify(:phase_validation_attempts_exhausted, _evidence), do: :validation_phase_exhausted

  def classify(_trigger, _evidence), do: :unknown_loop_breaker_trigger
end
