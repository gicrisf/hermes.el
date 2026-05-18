# Plan: Wire `config.get/set`, `tools.configure`, and dedicated helpers

## Decisions

1. **Dedicated helpers**: high-value subset only — `model`, `fast`, `reasoning`, `yolo`, `personality`, `skin`.
2. **Toolset UI**: simple minibuffer (`completing-read-multiple`) — Option A.
3. **Model completion**: dynamic fetch via `config.get provider` → `providers` list at call time.

---

## New file: `hermes-config.el`

### Generic building blocks

```elisp
(defun hermes-config-get (key &optional callback)
  "Send config.get for KEY. Call CALLBACK (result error) when response arrives.")

(defun hermes-config-set (key value &optional callback)
  "Send config.set for KEY → VALUE. Call CALLBACK (result error) when response arrives.")

(defun hermes--config-resolve-target ()
  "Return (SID . BUF) for the current target session, or signal user-error.")
```

Pattern: resolve target → extract `sid` → `hermes-rpc-request` with `(:key key :value value :session_id sid)`.

### Model helper

```elisp
(defun hermes-set-model (model)
  "Set the model for the current session.
Guard: if a stream is in flight, warn the user to /interrupt first."
  (interactive
   (list
    (progn
      ;; fetch providers dynamically, then completing-read
      (let* ((result (blocking-call-to-config-get-provider))  ; see approach below
             (providers (gethash "providers" result))
             (current (gethash "model" result))
             (candidates ...))
        (completing-read (format "Model (current %s): " current) candidates nil nil
                         (hermes--model-short-name current))))))
  ...)
```

**Dynamic fetch approach:** `config.get provider` returns immediately (no long handler), so we can use a synchronous `hermes-rpc-request` with a callback that stores the result in a dynamically bound variable, or we can simply call `config.get provider` inline in the `interactive` form with a short timeout. Simpler: fetch once on first call and cache in `hermes--last-model-providers` (buffer-local on the parent buffer). If cache is stale or nil, fire `config.get provider` and cache the result.

### Toggle helpers

```elisp
(defun hermes-toggle-fast ()
  (interactive)
  (hermes-config-set "fast" "toggle"
    (lambda (r e)
      (if e (message "hermes: fast toggle error: %S" e)
        (message "hermes: fast mode → %s" (gethash "value" r))))))

(defun hermes-toggle-reasoning ()
  (interactive)
  ;; Cycle through show/hide/low/medium/high
  (hermes-config-get "reasoning"
    (lambda (r e)
      (let ((current (gethash "value" r)))
        ...))))

(defun hermes-toggle-yolo ()
  (interactive)
  (hermes-config-set "yolo" "toggle" ...))
```

### Skin / personality helpers

```elisp
(defun hermes-set-personality (personality)
  (interactive (list (completing-read "Personality: " ...)))
  (hermes-config-set "personality" personality ...))

(defun hermes-set-skin (skin)
  (interactive (list (completing-read "Skin: " ...)))
  (hermes-config-set "skin" skin ...))
```

For `personality` and `skin`, there is no `config.get` list endpoint. Use free-form `completing-read` with nil completion table, or fetch from `config.get full` → `config.yaml` hints if we want to be fancy. For now: free-form.

### Toolset management

```elisp
(defun hermes-toolsets-toggle ()
  "Enable or disable toolsets via minibuffer completion.
Fetches current toolset list via toolsets.list, lets user pick names,
then prompts for action (enable/disable) and calls tools.configure."
  (interactive)
  (hermes-rpc-request
   "toolsets.list" nil
   (lambda (result error)
     (if error (message "hermes: toolsets.list error: %S" error)
       (let* ((toolsets (gethash "toolsets" result))
              (names (mapcar (lambda (ts) (gethash "name" ts)) toolsets))
              (chosen (completing-read-multiple "Toolsets: " names nil t))
              (action (completing-read "Action: " '("enable" "disable") nil t)))
         ...)))))
```

`completing-read-multiple` is built into Emacs 27.1+. Annotate each candidate with enabled status by passing an alist instead of a flat list.

## Files to touch

| File | Change |
|------|--------|
| `hermes-config.el` | **New file** — all RPC wrappers + 6 interactive commands + toolset helper |
| `hermes-mode.el` | `(require 'hermes-config)` after `(require 'hermes-bench)`; add vanilla keybindings to `hermes-mode-map` |
| `doom-hermes.el` | Add `SPC h m/f/r/y/t` leader bindings |
| `hermes-events.el` | Add `"toolsets.list"` to `hermes-rpc-methods` |
| `AGENTS.md` | Document the new commands and keybindings |

## Vanilla keybindings to add

```elisp
(define-key hermes-mode-map (kbd "C-c C-m") #'hermes-set-model)
(define-key hermes-mode-map (kbd "C-c C-f") #'hermes-toggle-fast)
```

## Doom keybindings to add

```elisp
(define-key hermes-leader-map (kbd "m") #'hermes-set-model)
(define-key hermes-leader-map (kbd "f") #'hermes-toggle-fast)
(define-key hermes-leader-map (kbd "r") #'hermes-toggle-reasoning)
(define-key hermes-leader-map (kbd "y") #'hermes-toggle-yolo)
(define-key hermes-leader-map (kbd "t") #'hermes-toolsets-toggle)
```

## Model guard

`config.set model` is rejected by the gateway if a turn is in-flight. The Emacs command should proactively check `(hermes-state-stream hermes--state)` and signal a `user-error` telling the user to run `M-x hermes-interrupt` (or `/interrupt`) first. This is better UX than sending the RPC and getting an opaque error back.

## Caching strategy for model providers

Buffer-local var `hermes-config--last-providers` holds the last `config.get provider` result as a hash table. It is refreshed:
- On first call to `hermes-set-model` when nil.
- On explicit prefix arg (`C-u M-x hermes-set-model`).
- Never auto-refreshed otherwise (provider lists change rarely).
