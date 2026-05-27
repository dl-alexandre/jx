defmodule JX.Agent.Protocol do
  @moduledoc """
  Behaviour for Agent Adapters in jx.

  Any external agent (Claude, Cursor, Aider, custom tools, etc.) can implement
  this behaviour to integrate with the jx orchestration system.

  This is the foundation of the "Agent Integration Layer" described in the
  architecture evolution plan.
  """

  @type session_id :: String.t()
  @type observation :: map()
  @type approval_request :: map()
  @type handoff :: map()
  @type result :: {:ok, map()} | {:error, term()}

  @doc """
  Report an observation from an agent session.
  """
  @callback report_observation(session_id, observation) :: result()

  @doc """
  Request approval for a proposed action.
  """
  @callback request_approval(approval_request) :: result()

  @doc """
  Record a handoff to another agent or human operator.
  """
  @callback handoff(handoff) :: result()

  @doc """
  Get current status for the agent (active work, blocks, approvals, etc.).
  """
  @callback get_status(opts :: keyword()) :: result()

  @optional_callbacks [get_status: 1]
end
