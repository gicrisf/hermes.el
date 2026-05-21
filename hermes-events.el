;;; hermes-events.el --- Event and method registry for Hermes gateway -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Version: 0.1.0
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Names of every gateway event the TUI may receive, and every JSON-RPC
;; method the TUI may call.  Kept as defconsts so the reducer, renderer,
;; and dispatcher can all reference the same source of truth and so that
;; bad names fail loudly at compile time instead of silently at runtime.

;;; Code:

;;;; Incoming events (gateway → TUI)
;;
;; Frames are JSON-RPC notifications of the form:
;;   {"jsonrpc":"2.0","method":"event",
;;    "params":{"type":"<name>", "session_id":"<sid>", "payload":{...}}}
;; See tui_gateway/server.py:382-386.

(defconst hermes-events-incoming
  '(;; Lifecycle
    "gateway.ready"          ; {skin}
    "session.info"           ; {model, tools, skills, cwd, lazy, ...}
    "skin.changed"           ; {skin}
    "reasoning.available"    ; {available}
    ;; Assistant message stream
    "message.start"          ; {}
    "message.delta"          ; {text, rendered?}
    "message.complete"       ; {finish_reason?, tokens_sent?, tokens_received?}
    "thinking.delta"         ; {text}
    "reasoning.delta"        ; {text}
    "status.update"          ; {kind, text}
    ;; Tools
    "tool.generating"        ; {name, tool_id}
    "tool.start"             ; {tool_id, name, context}
    "tool.progress"          ; {name, tool_id, preview}
    "tool.complete"          ; {name, tool_id, output, error?, exit_code?, duration_s?}
    ;; Subagents
    "subagent.spawn_requested"  ; {subagent_id, goal}
    "subagent.start"            ; {subagent_id, goal}
    "subagent.thinking"         ; {subagent_id, text}
    "subagent.tool"             ; {subagent_id, tool_name, args}
    "subagent.progress"         ; {subagent_id, note}
    "subagent.complete"         ; {subagent_id, status, summary, duration_s}
    ;; Blocking prompts
    "approval.request"       ; {request_id, command, description, ...}
    "clarify.request"        ; {request_id, question, choices}
    "sudo.request"           ; {request_id}
    "secret.request"         ; {request_id, env_var, prompt}
    ;; Gateway lifecycle / diagnostics
    "gateway.stderr"         ; {line}  — raw stderr line from subprocess
    "gateway.start_timeout"  ; {lines} — last stderr tail when gateway fails to start
    "gateway.protocol_error" ; {preview} — truncated raw frame that failed JSON parse
    ;; Background / review
    "background.complete"    ; {task_id, text}
    "review.summary"         ; {text}
    ;; Other
    "error"                  ; {message}
    "browser.progress"       ; v1: no-op
    "voice.status"           ; v1: no-op
    "voice.transcript")      ; v1: no-op
  "All gateway event types the Emacs client may receive.")

;;;; Outgoing requests (TUI → gateway)
;;
;; Frames are JSON-RPC 2.0 requests with auto-incrementing integer id.
;; See tui_gateway/server.py:427 for response echo behaviour.

(defconst hermes-rpc-methods
  '(;; Session lifecycle
    "session.create"         ; {cols?}                       → {session_id}
    "session.resume"         ; {session_id}                  (long handler, async) → {session_id, resumed, message_count, messages, info}
    "session.close"          ; {session_id}
    "session.interrupt"      ; {session_id}
    "session.list"           ; {limit?, cwd?}                → [{id, title, preview, started_at, message_count, source}]
    "session.branch"         ; {session_id, name?}           (long handler, async) → {session_id, title, parent}
    "session.delete"         ; {session_id}                  → bool
    "session.save"           ; {session_id}                  → {file}
    ;; Conversation
    "prompt.submit"          ; {session_id, text}
    "prompt.background"      ; {session_id, text}            → {task_id}
    "session.steer"          ; {session_id, text}            → {status, text}
    ;; Blocking prompt responses (echo request_id)
    "approval.respond"       ; {session_id, request_id, choice, all?}
    "clarify.respond"        ; {request_id, answer}
    "sudo.respond"           ; {request_id, password}
    "secret.respond"         ; {request_id, value}
    ;; Slash and commands
    "slash.exec"             ; {session_id, command}         (long handler, async)
    "shell.exec"             ; {command}                     → {stdout, stderr, code}
    "command.dispatch"       ; {session_id?, name, arg}
    "commands.catalog"       ; {} → {pairs, sub, canon, categories, skill_count, warning}
    ;; Config + tools
    "config.get"             ; {key, session_id?}            → key-dependent payload
    "config.set"             ; {key, value, session_id?}     → {key, value, ...}
    "toolsets.list"          ; {session_id?}                 → {toolsets:[{name, enabled, ...}]}
    "tools.configure"        ; {session_id?, action, names}  → {changed, enabled_toolsets, ...}
    ;; Skills
    "skills.reload"          ; {}                            → {output, result:{added, removed, total}}
    "skills.manage"          ; {action, query?, page?, page_size?} (long handler, async)
    ;; Multimodal attachments
    "image.attach"           ; {session_id, path}            → {attached, path, name, width, height, token_estimate}
    "clipboard.paste"        ; {session_id}                  → {attached, path, name, width, height, token_estimate}
    "input.detect_drop")     ; {session_id, text}            → {matched, is_image?, path?, text?, name?, width?, height?}
  "All JSON-RPC methods the Emacs client may invoke.")

;;;; Methods that the gateway dispatches to a worker pool.
;;
;; Responses arrive asynchronously and may interleave with other frames.
;; See tui_gateway/server.py:146-156.

(defconst hermes-rpc-long-handlers
  '("cli.exec"
    "slash.exec"
    "shell.exec"
    "session.resume"
    "session.branch"
    "session.compress"
    "skills.manage"
    "browser.manage")
  "Methods the gateway processes asynchronously in a thread pool.")

(provide 'hermes-events)
;;; hermes-events.el ends here
