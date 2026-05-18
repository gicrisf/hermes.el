# Plan: Wire `session.steer`

## Decisions

- **Option C**: Respect gateway `busy` config for RET behavior + explicit `C-c C-s` steer command.
- **Unknown busy mode**: default to `queue` (current behavior, safe).
- **Steer visibility**: Show steer messages in bench ephemeral area with `[steer]` prefix.
- **Steer does not create committed turn**: No Org buffer heading, just injects into stream.

---

## RPC method

`session.steer` — `{session_id, text}` → `{status: "queued" | "rejected", text}`

Safe mid-turn, no interrupt needed. Also available as `/steer <text>` slash command.

---

## Files to touch

### `hermes-events.el`

Add `"session.steer"` to `hermes-rpc-methods`.

### `hermes-state.el`

1. Add `busy-mode` slot to `hermes-state` struct (default `nil`).
2. Update reducer for `"session.info"`: extract `busy` field from payload into `busy-mode`.

### `hermes-input.el`

Modify `hermes-input--send-1` busy branch (currently lines 334-337):

```elisp
((hermes-state-stream hermes--state)
 (pcase (hermes-state-busy-mode hermes--state)
   ('steer
    (hermes-rpc-request
     "session.steer"
     (list :session_id sid :text text)
     (lambda (r e)
       (cond
        (e (message "hermes: steer error: %S" e))
        ((equal (gethash "status" r) "rejected")
         (message "hermes: steer rejected"))
        (t (message "hermes: steer queued"))))))
   ('interrupt
    (hermes-interrupt)
    ;; After interrupt, the stream clears; the drain hook will
    ;; process the queue. Push the text onto the queue.
    (hermes-dispatch (cons :enqueue (list :text text))))
   (_ ;; queue (default when unknown)
    (hermes-dispatch (cons :enqueue (list :text text)))
    (message "Hermes: Message queued (%d ahead of you)"
             (length (hermes-state-queue hermes--state))))))
```

### `hermes-bench.el`

1. Add `hermes-bench-steer` function:
   - Read text from input area
   - Call `hermes-steer` (defined in `hermes-config.el`)
   - Show `[steer] <text>` in ephemeral area immediately

2. Bind `C-c C-s` in `hermes-bench-mode-map`.

3. Add `hermes-bench--paint-steer` helper:
   - Insert `[steer] <text>` above reasoning zone with a distinct face
   - Or: prepend `[steer]` to the existing user prompt display

### `hermes-config.el`

Add `hermes-steer` function (callable from anywhere):

```elisp
(defun hermes-steer (text)
  "Send TEXT as a steer message to the current session's in-flight turn."
  (interactive (list (read-string "Steer: ")))
  (let ((sid (hermes--config-resolve-target)))
    (hermes-rpc-request
     "session.steer"
     (list :session_id sid :text text)
     (lambda (r e)
       (cond
        (e (message "hermes: steer error: %S" e))
        ((equal (gethash "status" r) "rejected")
         (message "hermes: steer rejected"))
        (t (message "hermes: steer queued")))))))
```

### `doom-hermes.el`

Add `SPC h S` (capital S for steer) or `SPC h C-s` binding.

---

## Bench ephemeral area display

When a steer message is sent, the bench should show it above the reasoning/answer zones:

```
** U: original user prompt

[steer] please focus on the async data race

*** Reasoning
...
```

Implementation: add `hermes-bench--steer-messages` (buffer-local list of strings). On `hermes-bench--paint-ephemeral`, if the list is non-empty, insert each steer message with `[steer] ` prefix and `hermes-bench-steer-face` before the reasoning zone.

Clear the list on `stream-commit` (turn ends).

---

## Open questions (none — all resolved)

1. Default when unknown busy: `queue` ✅
2. Special prefix: `[steer]` ✅
3. Show in bench: yes, above reasoning ✅
