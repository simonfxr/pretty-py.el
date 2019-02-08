# Pretty-Py

Pretty-Py allows you to format your Python code using standard tools, currently supports:
- _yapf_ (default)
- _autopep8_
- _black_

## Why yet another emacs package?
- Unified interface for on the fly switching between different Python code formatters.
- Afaict all of the existing packages just replace your whole buffer which the new formatted content. This packages uses a smart diff mode to only make minimal changes to your buffer (adapted from [_go-mode.el_](https://github.com/dominikh/go-mode.el)). This has some a number of advantages, it's faster, it avoids font-locking your whole code a again and has better undo behavior. 
- Supports _blackd_, the http daemon for _black_, avoiding repeated startup time. Hence this is the recommended option when using the `before-save-hook`.

## Installation and Usage

- Currently you have to fetch it from github, melpa upload pending.
- Make sure your preferred formatter is installed. If it is your path `pretty-py` will find it, otherwise set `pretty-py-{yapf,autopep8,black}-command` explicitly.
- If you want to automatically format on every save, enable the minor mode `pretty-py-mode` from within your `python-mode-hook`.
- To format your buffer invoke `pretty-py-buffer`, `pretty-py-buffer-yapf`, `pretty-py-buffer-autopep8` or `pretty-py-buffer-black` as required.

### Example configuration:
```elisp
(defun my-python-mode-hook ()
  (pretty-py-mode 1))

(use-package pretty-py
  :init
  (add-hook 'python-mode-hook #'my-python-mode-hook)
  :config
  (setq pretty-py-formatter 'black
        pretty-py-use-blackd t
        pretty-py-black-fast-flag t
        pretty-py-black-line-length 79))
```
