;;; magit-branch.el --- branch support  -*- lexical-binding: t -*-

;; Copyright (C) 2010-2018  The Magit Project Contributors
;;
;; You should have received a copy of the AUTHORS.md file which
;; lists all contributors.  If not, see http://magit.vc/authors.

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>

;; Magit is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see http://www.gnu.org/licenses.

;;; Commentary:

;; This library implements support for branches.  It defines popups
;; and commands for creating, checking out, manipulating, and
;; configuring branches.  Commands defined here are mainly concerned
;; with branches as pointers, commands that deal with what a branch
;; points at, are defined elsewhere.

;;; Code:

(eval-when-compile
  (require 'subr-x))

(require 'magit)
(require 'magit-reset)

;;; Options

(defcustom magit-branch-read-upstream-first t
  "Whether to read upstream before name of new branch when creating a branch.

`nil'      Read the branch name first.
`t'        Read the upstream first.
`fallback' Read the upstream first, but if it turns out that the chosen
           value is not a valid upstream (because it cannot be resolved
           as an existing revision), then treat it as the name of the
           new branch and continue by reading the upstream next."
  :package-version '(magit . "2.2.0")
  :group 'magit-commands
  :type '(choice (const :tag "read branch name first" nil)
                 (const :tag "read upstream first" t)
                 (const :tag "read upstream first, with fallback" fallback)))

(defcustom magit-branch-prefer-remote-upstream nil
  "Whether to favor remote upstreams when creating new branches.

When a new branch is created, then the branch, commit, or stash
at point is suggested as the default starting point of the new
branch, or if there is no such revision at point the current
branch.  In either case the user may choose another starting
point.

If the chosen starting point is a branch, then it may also be set
as the upstream of the new branch, depending on the value of the
Git variable `branch.autoSetupMerge'.  By default this is done
for remote branches, but not for local branches.

You might prefer to always use some remote branch as upstream.
If the chosen starting point is (1) a local branch, (2) whose
name matches a member of the value of this option, (3) the
upstream of that local branch is a remote branch with the same
name, and (4) that remote branch can be fast-forwarded to the
local branch, then the chosen branch is used as starting point,
but its own upstream is used as the upstream of the new branch.

Members of this option's value are treated as branch names that
have to match exactly unless they contain a character that makes
them invalid as a branch name.  Recommended characters to use
to trigger interpretation as a regexp are \"*\" and \"^\".  Some
other characters which you might expect to be invalid, actually
are not, e.g. \".+$\" are all perfectly valid.  More precisely,
if `git check-ref-format --branch STRING' exits with a non-zero
status, then treat STRING as a regexp.

Assuming the chosen branch matches these conditions you would end
up with with e.g.:

  feature --upstream--> origin/master

instead of

  feature --upstream--> master --upstream--> origin/master

Which you prefer is a matter of personal preference.  If you do
prefer the former, then you should add branches such as \"master\",
\"next\", and \"maint\" to the value of this options."
  :package-version '(magit . "2.4.0")
  :group 'magit-commands
  :type '(repeat string))

(defcustom magit-branch-adjust-remote-upstream-alist nil
  "Alist of upstreams to be used when branching from remote branches.

When creating a local branch from an ephemeral branch located
on a remote, e.g. a feature or hotfix branch, then that remote
branch should usually not be used as the upstream branch, since
the push-remote already allows accessing it and having both the
upstream and the push-remote reference the same related branch
would be wasteful.  Instead a branch like \"maint\" or \"master\"
should be used as the upstream.

This option allows specifying the branch that should be used as
the upstream when branching certain remote branches.  The value
is an alist of the form ((UPSTREAM . RULE)...).  The first
matching element is used, the following elements are ignored.

UPSTREAM is the branch to be used as the upstream for branches
specified by RULE.  It can be a local or a remote branch.

RULE can either be a regular expression, matching branches whose
upstream should be the one specified by UPSTREAM.  Or it can be
a list of the only branches that should *not* use UPSTREAM; all
other branches will.  Matching is done after stripping the remote
part of the name of the branch that is being branched from.

If you use a finite set of non-ephemeral branches across all your
repositories, then you might use something like:

  ((\"origin/master\" \"master\" \"next\" \"maint\"))

Or if the names of all your ephemeral branches contain a slash,
at least in some repositories, then a good value could be:

  ((\"origin/master\" . \"/\"))

Of course you can also fine-tune:

  ((\"origin/maint\" . \"\\\\\\=`hotfix/\")
   (\"origin/master\" . \"\\\\\\=`feature/\"))

If you use remote branches as UPSTREAM, then you might also want
to set `magit-branch-prefer-remote-upstream' to a non-nil value.
However, I recommend that you use local branches as UPSTREAM."
  :package-version '(magit . "2.9.0")
  :group 'magit-commands
  :type '(repeat (cons (string :tag "Use upstream")
                       (choice :tag "for branches"
                               (regexp :tag "matching")
                               (repeat :tag "except"
                                       (string :tag "branch"))))))

(defcustom magit-branch-rename-push-target t
  "Whether the push-remote setup is preserved when renaming a branch.

The command `magit-branch-rename' renames a branch named OLD to
NEW.  This option controls how much of the push-remote setup is
preserved when doing so.

When nil, then preserve nothing and unset `branch.OLD.pushRemote'.

When `local-only', then first set `branch.NEW.pushRemote' to the
  same value as `branch.OLD.pushRemote', provided the latter is
  actually set and unless the former already has another value.

When t, then rename the branch named OLD on the remote specified
  by `branch.OLD.pushRemote' to NEW, provided OLD exists on that
  remote and unless NEW already exists on the remote.

When `forge-only' and the `forge' package is available, then
  behave like `t' if the remote points to a repository on a forge
  (currently Github or Gitlab), otherwise like `local-only'.

Another supported but obsolete value is `github-only'.  It is a
  misnomer because it now treated as an alias for `forge-only'."
  :package-version '(magit . "2.90.0")
  :group 'magit-commands
  :type '(choice
          (const :tag "Don't preserve push-remote setup" nil)
          (const :tag "Preserve push-remote setup" local-only)
          (const :tag "... and rename corresponding branch on remote" t)
          (const :tag "... but only if remote is on a forge" forge-only)))

(defcustom magit-branch-popup-show-variables t
  "Whether the `magit-branch-popup' shows Git variables.
This defaults to t to avoid changing key bindings.  When set to
nil, no variables are displayed directly in this popup, instead
the sub-popup `magit-branch-configure' has to be used to view
and change branch related variables."
  :package-version '(magit . "2.7.0")
  :group 'magit-commands
  :type 'boolean)

(defcustom magit-published-branches '("origin/master")
  "List of branches that are considered to be published."
  :package-version '(magit . "2.13.0")
  :group 'magit-commands
  :type '(repeat string))

;;; Branch Popup

(defvar magit-branch-config-variables)

;;;###autoload (autoload 'magit-branch-popup "magit" nil t)
(magit-define-popup magit-branch-popup
  "Popup console for branch commands."
  :man-page "git-branch"
  :variables (lambda ()
               (and magit-branch-popup-show-variables
                    magit-branch-config-variables))
  :actions '((?b "Checkout"              magit-checkout) nil
             (?C "Configure..."          magit-branch-configure)
             (?l "Checkout local branch" magit-branch-checkout)
             (?s "Create new spin-off"   magit-branch-spinoff)
             (?m "Rename"                magit-branch-rename)
             (?c "Checkout new branch"   magit-branch-and-checkout)
             (?n "Create new branch"     magit-branch-create)
             (?x "Reset"                 magit-branch-reset)
             (?w "Checkout new worktree" magit-worktree-checkout)
             (?W "Create new worktree"   magit-worktree-branch)
             (?k "Delete"                magit-branch-delete))
  :default-action 'magit-checkout
  :max-action-columns 3
  :setup-function 'magit-branch-popup-setup)

(defun magit-branch-popup-setup (val def)
  (magit-popup-default-setup val def)
  (use-local-map (copy-keymap magit-popup-mode-map))
  (dolist (ev (-filter #'magit-popup-event-p (magit-popup-get :variables)))
    (local-set-key (vector (magit-popup-event-key ev))
                   'magit-invoke-popup-action)))

;;; Branch Commands

;;;###autoload
(defun magit-checkout (revision)
  "Checkout REVISION, updating the index and the working tree.
If REVISION is a local branch, then that becomes the current
branch.  If it is something else, then `HEAD' becomes detached.
Checkout fails if the working tree or the staging area contain
changes.
\n(git checkout REVISION)."
  (interactive (list (magit-read-other-branch-or-commit "Checkout")))
  (when (string-match "\\`heads/\\(.+\\)" revision)
    (setq revision (match-string 1 revision)))
  (magit-run-git "checkout" revision))

;;;###autoload
(defun magit-branch-create (branch start-point &optional args)
  "Create BRANCH at branch or revision START-POINT.
\n(git branch [ARGS] BRANCH START-POINT)."
  (interactive (magit-branch-read-args "Create branch"))
  (magit-call-git "branch" args branch start-point)
  (magit-branch-maybe-adjust-upstream branch start-point)
  (magit-refresh))

;;;###autoload
(defun magit-branch-and-checkout (branch start-point &optional args)
  "Create and checkout BRANCH at branch or revision START-POINT.
\n(git checkout [ARGS] -b BRANCH START-POINT)."
  (interactive (magit-branch-read-args "Create and checkout branch"))
  (if (string-match-p "^stash@{[0-9]+}$" start-point)
      (magit-run-git "stash" "branch" branch start-point)
    (magit-call-git "checkout" args "-b" branch start-point)
    (magit-branch-maybe-adjust-upstream branch start-point)
    (magit-refresh)))

;;;###autoload
(defun magit-branch-or-checkout (arg &optional start-point)
  "Hybrid between `magit-checkout' and `magit-branch-and-checkout'.

Ask the user for an existing branch or revision.  If the user
input actually can be resolved as a branch or revision, then
check that out, just like `magit-checkout' would.

Otherwise create and checkout a new branch using the input as
its name.  Before doing so read the starting-point for the new
branch.  This is similar to what `magit-branch-and-checkout'
does."
  (interactive
   (let ((arg (magit-read-other-branch-or-commit "Checkout")))
     (list arg
           (and (not (magit-commit-p arg))
                (magit-read-starting-point "Create and checkout branch" arg)))))
  (when (string-match "\\`heads/\\(.+\\)" arg)
    (setq arg (match-string 1 arg)))
  (if start-point
      (magit-branch-and-checkout arg start-point (magit-branch-arguments))
    (magit-checkout arg)))

;;;###autoload
(defun magit-branch-checkout (branch &optional start-point)
  "Checkout an existing or new local branch.

Read a branch name from the user offering all local branches and
a subset of remote branches as candidates.  Omit remote branches
for which a local branch by the same name exists from the list
of candidates.  The user can also enter a completely new branch
name.

- If the user selects an existing local branch, then check that
  out.

- If the user selects a remote branch, then create and checkout
  a new local branch with the same name.  Configure the selected
  remote branch as push target.

- If the user enters a new branch name, then create and check
  that out, after also reading the starting-point from the user.

In the latter two cases the upstream is also set.  Whether it is
set to the chosen START-POINT or something else depends on the
value of `magit-branch-adjust-remote-upstream-alist', just like
when using `magit-branch-and-checkout'."
  (interactive
   (let* ((current (magit-get-current-branch))
          (local   (magit-list-local-branch-names))
          (remote  (--filter (and (string-match "[^/]+/" it)
                                  (not (member (substring it (match-end 0))
                                               (cons "HEAD" local))))
                             (magit-list-remote-branch-names)))
          (choices (nconc (delete current local) remote))
          (atpoint (magit-branch-at-point))
          (choice  (magit-completing-read
                    "Checkout branch" choices
                    nil nil nil 'magit-revision-history
                    (or (car (member atpoint choices))
                        (and atpoint
                             (car (member (and (string-match "[^/]+/" atpoint)
                                               (substring atpoint (match-end 0)))
                                          choices)))))))
     (cond ((member choice remote)
            (list (and (string-match "[^/]+/" choice)
                       (substring choice (match-end 0)))
                  choice))
           ((member choice local)
            (list choice))
           (t
            (list choice (magit-read-starting-point "Create" choice))))))
  (if (not start-point)
      (magit-checkout branch)
    (when (magit-anything-modified-p)
      (user-error "Cannot checkout when there are uncommitted changes"))
    (magit-branch-and-checkout branch start-point (magit-branch-arguments))
    (when (magit-remote-branch-p start-point)
      (pcase-let ((`(,remote . ,remote-branch)
                   (magit-split-branch-name start-point)))
        (when (and (equal branch remote-branch)
                   (not (equal remote (magit-get "remote.pushDefault"))))
          (magit-set remote "branch" branch "pushRemote"))))))

(defun magit-branch-maybe-adjust-upstream (branch start-point)
  (--when-let
      (or (and (magit-get-upstream-branch branch)
               (magit-get-indirect-upstream-branch start-point))
          (and (magit-remote-branch-p start-point)
               (let ((name (cdr (magit-split-branch-name start-point))))
                 (car (--first (if (listp (cdr it))
                                   (not (member name (cdr it)))
                                 (string-match-p (cdr it) name))
                               magit-branch-adjust-remote-upstream-alist)))))
    (magit-call-git "branch" (concat "--set-upstream-to=" it) branch)))

;;;###autoload
(defun magit-branch-orphan (branch start-point &optional args)
  "Create and checkout an orphan BRANCH with contents from revision START-POINT.
\n(git checkout --orphan [ARGS] BRANCH START-POINT)."
  (interactive (magit-branch-read-args "Create and checkout orphan branch"))
  (magit-run-git "checkout" "--orphan" args branch start-point))

(defun magit-branch-read-args (prompt)
  (let ((args (magit-branch-arguments)))
    (if magit-branch-read-upstream-first
        (let ((choice (magit-read-starting-point prompt)))
          (if (magit-rev-verify choice)
              (list (magit-read-string-ns
                     (if magit-completing-read--silent-default
                         (format "%s (starting at `%s')" prompt choice)
                       "Name for new branch")
                     (let ((def (mapconcat #'identity
                                           (cdr (split-string choice "/"))
                                           "/")))
                       (and (member choice (magit-list-remote-branch-names))
                            (not (member def (magit-list-local-branch-names)))
                            def)))
                    choice args)
            (if (eq magit-branch-read-upstream-first 'fallback)
                (list choice (magit-read-starting-point prompt choice) args)
              (user-error "Not a valid starting-point: %s" choice))))
      (let ((branch (magit-read-string-ns (concat prompt " named"))))
        (list branch
              (magit-read-starting-point prompt branch)
              args)))))

;;;###autoload
(defun magit-branch-spinoff (branch &optional from &rest args)
  "Create new branch from the unpushed commits.

Create and checkout a new branch starting at and tracking the
current branch.  That branch in turn is reset to the last commit
it shares with its upstream.  If the current branch has no
upstream or no unpushed commits, then the new branch is created
anyway and the previously current branch is not touched.

This is useful to create a feature branch after work has already
began on the old branch (likely but not necessarily \"master\").

If the current branch is a member of the value of option
`magit-branch-prefer-remote-upstream' (which see), then the
current branch will be used as the starting point as usual, but
the upstream of the starting-point may be used as the upstream
of the new branch, instead of the starting-point itself.

If optional FROM is non-nil, then the source branch is reset
to `FROM~', instead of to the last commit it shares with its
upstream.  Interactively, FROM is only ever non-nil, if the
region selects some commits, and among those commits, FROM is
the commit that is the fewest commits ahead of the source
branch.

The commit at the other end of the selection actually does not
matter, all commits between FROM and `HEAD' are moved to the new
branch.  If FROM is not reachable from `HEAD' or is reachable
from the source branch's upstream, then an error is raised."
  (interactive (list (magit-read-string-ns "Spin off branch")
                     (car (last (magit-region-values 'commit)))
                     (magit-branch-arguments)))
  (when (magit-branch-p branch)
    (user-error "Cannot spin off %s.  It already exists" branch))
  (if-let ((current (magit-get-current-branch)))
      (let ((tracked (magit-get-upstream-branch current))
            base)
        (when from
          (unless (magit-rev-ancestor-p from current)
            (user-error "Cannot spin off %s.  %s is not reachable from %s"
                        branch from current))
          (when (and tracked
                     (magit-rev-ancestor-p from tracked))
            (user-error "Cannot spin off %s.  %s is ancestor of upstream %s"
                        branch from tracked)))
        (let ((magit-process-raise-error t))
          (magit-call-git "checkout" args "-b" branch current))
        (--when-let (magit-get-indirect-upstream-branch current)
          (magit-call-git "branch" "--set-upstream-to" it branch))
        (when (and tracked
                   (setq base
                         (if from
                             (concat from "^")
                           (magit-git-string "merge-base" current tracked)))
                   (not (magit-rev-eq base current)))
          (magit-call-git "update-ref" "-m"
                          (format "reset: moving to %s" base)
                          (concat "refs/heads/" current) base))
        (magit-refresh))
    (magit-run-git "checkout" "-b" branch)))

;;;###autoload
(defun magit-branch-reset (branch to &optional args set-upstream)
  "Reset a branch to the tip of another branch or any other commit.

When the branch being reset is the current branch, then do a
hard reset.  If there are any uncommitted changes, then the user
has to confirm the reset because those changes would be lost.

This is useful when you have started work on a feature branch but
realize it's all crap and want to start over.

When resetting to another branch and a prefix argument is used,
then also set the target branch as the upstream of the branch
that is being reset."
  (interactive
   (let* ((atpoint (magit-local-branch-at-point))
          (branch  (magit-read-local-branch "Reset branch" atpoint)))
     (list branch
           (magit-completing-read (format "Reset %s to" branch)
                                  (delete branch (magit-list-branch-names))
                                  nil nil nil 'magit-revision-history
                                  (or (and (not (equal branch atpoint)) atpoint)
                                      (magit-get-upstream-branch branch)))
           (magit-branch-arguments)
           current-prefix-arg)))
  (unless (member "--force" args)
    (setq args (cons "--force" args)))
  (if (equal branch (magit-get-current-branch))
      (if (and (magit-anything-modified-p)
               (not (yes-or-no-p "Uncommitted changes will be lost.  Proceed? ")))
          (user-error "Abort")
        (magit-reset-hard to)
        (when (and set-upstream (magit-branch-p to))
          (magit-set-upstream-branch branch to)))
    (magit-branch-create branch to args)))

;;;###autoload
(defun magit-branch-delete (branches &optional force)
  "Delete one or multiple branches.
If the region marks multiple branches, then offer to delete
those, otherwise prompt for a single branch to be deleted,
defaulting to the branch at point."
  ;; One would expect this to be a command as simple as, for example,
  ;; `magit-branch-rename'; but it turns out everyone wants to squeeze
  ;; a bit of extra functionality into this one, including myself.
  (interactive
   (let ((branches (magit-region-values 'branch t))
         (force current-prefix-arg))
     (if (> (length branches) 1)
         (magit-confirm t nil "Delete %i branches" nil branches)
       (setq branches
             (list (magit-read-branch-prefer-other
                    (if force "Force delete branch" "Delete branch")))))
     (unless force
       (when-let ((unmerged (-remove #'magit-branch-merged-p branches)))
         (if (magit-confirm 'delete-unmerged-branch
               "Delete unmerged branch %s"
               "Delete %i unmerged branches"
               'noabort unmerged)
             (setq force branches)
           (or (setq branches (-difference branches unmerged))
               (user-error "Abort")))))
     (list branches force)))
  (let* ((refs (mapcar #'magit-ref-fullname branches))
         (ambiguous (--remove it refs)))
    (when ambiguous
      (user-error
       "%s ambiguous.  Please cleanup using git directly."
       (let ((len (length ambiguous)))
         (cond
          ((= len 1)
           (format "%s is" (-first #'magit-ref-ambiguous-p branches)))
          ((= len (length refs))
           (format "These %s names are" len))
          (t
           (format "%s of these names are" len))))))
    (cond
     ((string-match "^refs/remotes/\\([^/]+\\)" (car refs))
      (let* ((remote (match-string 1 (car refs)))
             (offset (1+ (length remote))))
        ;; Assume the branches actually still exists on the remote.
        (magit-run-git-async
         "push" remote (--map (concat ":" (substring it offset)) branches))
        ;; If that is not the case, then this deletes the tracking branches.
        (set-process-sentinel
         magit-this-process
         (apply-partially 'magit-delete-remote-branch-sentinel refs))))
     ((> (length branches) 1)
      (setq branches (delete (magit-get-current-branch) branches))
      (mapc 'magit-branch-maybe-delete-pr-remote branches)
      (mapc 'magit-branch-unset-pushRemote branches)
      (magit-run-git "branch" (if force "-D" "-d") branches))
     (t ; And now for something completely different.
      (let* ((branch (car branches))
             (prompt (format "Branch %s is checked out.  " branch)))
        (when (equal branch (magit-get-current-branch))
          (pcase (if (or (equal branch "master")
                         (not (magit-rev-verify "master")))
                     (magit-read-char-case prompt nil
                       (?d "[d]etach HEAD & delete" 'detach)
                       (?a "[a]bort"                'abort))
                   (magit-read-char-case prompt nil
                     (?d "[d]etach HEAD & delete"     'detach)
                     (?c "[c]heckout master & delete" 'master)
                     (?a "[a]bort"                    'abort)))
            (`detach (unless (or (equal force '(4))
                                 (member branch force)
                                 (magit-branch-merged-p branch t))
                       (magit-confirm 'delete-unmerged-branch
                         "Delete unmerged branch %s" ""
                         nil (list branch)))
                     (magit-call-git "checkout" "--detach"))
            (`master (unless (or (equal force '(4))
                                 (member branch force)
                                 (magit-branch-merged-p branch "master"))
                       (magit-confirm 'delete-unmerged-branch
                         "Delete unmerged branch %s" ""
                         nil (list branch)))
                     (magit-call-git "checkout" "master"))
            (`abort  (user-error "Abort")))
          (setq force t))
        (magit-branch-maybe-delete-pr-remote branch)
        (magit-branch-unset-pushRemote branch)
        (magit-run-git "branch" (if force "-D" "-d") branch))))))

(put 'magit-branch-delete 'interactive-only t)

(defun magit-branch-maybe-delete-pr-remote (branch)
  (when-let ((remote (magit-get "branch" branch "pullRequestRemote")))
    (let* ((variable (format "remote.%s.fetch" remote))
           (refspecs (magit-get-all variable)))
      (unless (member (format "+refs/heads/*:refs/remotes/%s/*" remote)
                      refspecs)
        (let ((refspec
               (if (equal (magit-get "branch" branch "pushRemote") remote)
                   (format "+refs/heads/%s:refs/remotes/%s/%s"
                           branch remote branch)
                 (let ((merge (magit-get "branch" branch "merge")))
                   (and merge
                        (string-prefix-p "refs/heads/" merge)
                        (setq merge (substring merge 11))
                        (format "+refs/heads/%s:refs/remotes/%s/%s"
                                merge remote merge))))))
          (when (member refspec refspecs)
            (if (and (= (length refspecs) 1)
                     (magit-confirm 'delete-pr-remote
                       (format "Also delete remote %s (%s)" remote
                               "no pull-request branch remains")))
                (magit-call-git "remote" "rm" remote)
              (magit-call-git "config" "--unset" variable
                              (regexp-quote refspec)))))))))

(defun magit-branch-unset-pushRemote (branch)
  (magit-set nil "branch" branch "pushRemote"))

(defun magit-delete-remote-branch-sentinel (refs process event)
  (when (memq (process-status process) '(exit signal))
    (if (= (process-exit-status process) 0)
        (magit-process-sentinel process event)
      (if-let ((rest (-filter #'magit-ref-exists-p refs)))
          (progn
            (process-put process 'inhibit-refresh t)
            (magit-process-sentinel process event)
            (setq magit-this-error nil)
            (message "Some remote branches no longer exist.  %s"
                     "Deleting just the local tracking refs instead...")
            (dolist (ref rest)
              (magit-call-git "update-ref" "-d" ref))
            (magit-refresh)
            (message "Deleting local remote-tracking refs...done"))
        (magit-process-sentinel process event)))))

;;;###autoload
(defun magit-branch-rename (old new &optional force)
  "Rename the branch named OLD to NEW.

With a prefix argument FORCE, rename even if a branch named NEW
already exists.

If `branch.OLD.pushRemote' is set, then unset it.  Depending on
the value of `magit-branch-rename-push-target' (which see) maybe
set `branch.NEW.pushRemote' and maybe rename the push-target on
the remote."
  (interactive
   (let ((branch (magit-read-local-branch "Rename branch")))
     (list branch
           (magit-read-string-ns (format "Rename branch '%s' to" branch)
                                 nil 'magit-revision-history)
           current-prefix-arg)))
  (when (string-match "\\`heads/\\(.+\\)" old)
    (setq old (match-string 1 old)))
  (when (equal old new)
    (user-error "Old and new branch names are the same"))
  (magit-call-git "branch" (if force "-M" "-m") old new)
  (when magit-branch-rename-push-target
    (let ((remote (magit-get-push-remote old))
          (old-specific (magit-get "branch" old "pushRemote"))
          (new-specific (magit-get "branch" new "pushRemote")))
      (when (and old-specific (or force (not new-specific)))
        ;; Keep the target setting branch specific, even if that is
        ;; redundant.  But if a branch by the same name existed before
        ;; and the rename isn't forced, then do not change a leftover
        ;; setting.  Such a leftover setting may or may not conform to
        ;; what we expect here...
        (magit-set old-specific "branch" new "pushRemote"))
      (when (and (equal (magit-get-push-remote new) remote)
                 ;; ...and if it does not, then we must abort.
                 (not (eq magit-branch-rename-push-target 'local-only))
                 (or (not (memq magit-branch-rename-push-target
                                '(forge-only github-only)))
                     (and (require (quote forge) nil t)
                          (fboundp 'forge--forge-remote-p)
                          (forge--forge-remote-p remote))))
        (let ((old-target (magit-get-push-branch old t))
              (new-target (magit-get-push-branch new t))
              (remote (magit-get-push-remote new)))
          (when (and old-target
                     (not new-target)
                     (magit-y-or-n-p (format "Also rename %S to %S on %S"
                                             old new remote)))
            ;; Rename on (i.e. within) the remote, but only if the
            ;; destination ref doesn't exist yet.  If that ref already
            ;; exists, then it probably is of some value and we better
            ;; not touch it.  Ignore what the local ref points at,
            ;; i.e. if the local and the remote ref didn't point at
            ;; the same commit before the rename then keep it that way.
            (magit-call-git "push" "-v" remote
                            (format "%s:refs/heads/%s" old-target new)
                            (format ":refs/heads/%s" old)))))))
  (magit-branch-unset-pushRemote old)
  (magit-refresh))

;;;###autoload
(defun magit-branch-shelve (branch)
  "Shelve a BRANCH.
Rename \"refs/heads/BRANCH\" to \"refs/shelved/BRANCH\",
and also rename the respective reflog file."
  (interactive (list (magit-read-other-local-branch "Shelve branch")))
  (let ((old (concat "refs/heads/"   branch))
        (new (concat "refs/shelved/" branch)))
    (magit-git "update-ref" new old "")
    (magit--rename-reflog-file old new)
    (magit-branch-unset-pushRemote branch)
    (magit-run-git "branch" "-D" branch)))

;;;###autoload
(defun magit-branch-unshelve (branch)
  "Unshelve a BRANCH
Rename \"refs/shelved/BRANCH\" to \"refs/heads/BRANCH\",
and also rename the respective reflog file."
  (interactive
   (list (magit-completing-read
          "Unshelve branch"
          (--map (substring it 8)
                 (magit-list-refnames "refs/shelved"))
          nil t)))
  (let ((old (concat "refs/shelved/" branch))
        (new (concat "refs/heads/"   branch)))
    (magit-git "update-ref" new old "")
    (magit--rename-reflog-file old new)
    (magit-run-git "update-ref" "-d" old)))

(defun magit--rename-reflog-file (old new)
  (let ((old (magit-git-dir (concat "logs/" old)))
        (new (magit-git-dir (concat "logs/" new))))
    (when (file-exists-p old)
      (make-directory (file-name-directory new) t)
      (rename-file old new t))))

;;; Configure

;;;###autoload (autoload 'magit-branch-configure "magit-branch" nil t)
(define-transient-command magit-branch-configure (branch)
  "Configure a branch."
  :man-page "git-branch"
  [:description
   (lambda ()
     (concat
      (propertize "Configure " 'face 'transient-heading)
      (propertize (oref transient--prefix scope) 'face 'magit-branch-local)))
   ("d"   magit-branch.<branch>.description)
   ("u"   magit-branch.<branch>.merge/remote)
   ("r"   magit-branch.<branch>.rebase)
   ("p"   magit-branch.<branch>.pushRemote)]
  ["Configure repository defaults"
   ("M-r" magit-pull.rebase)
   ("M-p" magit-remote.pushDefault)]
  ["Configure branch creation"
   ("U"   magit-branch.autoSetupMerge)
   ("R"   magit-branch.autoSetupRebase)]
  (interactive
   (list (or (and (not current-prefix-arg)
                  (not (and magit-branch-popup-show-variables
                            (eq current-transient-command 'magit-branch)))
                  (magit-get-current-branch))
             (magit-read-local-branch "Configure branch"))))
  (transient-setup 'magit-branch-configure nil :scope branch))

(define-suffix-command magit-branch.<branch>.description (branch)
  "TODO"
  :class 'magit--git-variable
  :transient nil
  :variable "branch.%s.description"
  (interactive (list (oref transient--prefix scope)))
  (magit-run-git-with-editor "branch" "--edit-description" branch))

(add-hook 'find-file-hook 'magit-branch-description-check-buffers)

(defun magit-branch-description-check-buffers ()
  (and buffer-file-name
       (string-match-p "/\\(BRANCH\\|EDIT\\)_DESCRIPTION\\'" buffer-file-name)))

(defclass magit--git-branch:upstream (magit--git-variable)
  ((format :initform " %k %m %M\n   %r  %R")))

(define-infix-argument magit-branch.<branch>.merge/remote ()
  :class 'magit--git-branch:upstream
  :variable '("branch.%s.merge" . "branch.%s.remote"))

(cl-defmethod transient-init-value ((obj magit--git-branch:upstream))
  (pcase-let ((`(,remote . ,merge) (oref obj variable))
              (branch (oref transient--prefix scope)))
    (oset obj variable
          (cons (format remote branch)
                (format merge  branch))))
  (when-let ((upstream (magit-get-upstream-branch)))
    (oset obj value (magit-split-branch-name upstream))))

(cl-defmethod transient-infix-read ((obj magit--git-branch:upstream))
  (if (oref obj value)
      (oset obj value nil)
    (magit-split-branch-name
     (magit-read-upstream-branch
      (oref transient--prefix scope)
      "Upstream"))))

(cl-defmethod transient-infix-set ((obj magit--git-branch:upstream) value)
  (oset obj value value)
  (magit-set-upstream-branch (oref transient--prefix scope) value)
  (magit-refresh))

(cl-defmethod transient-format ((obj magit--git-branch:upstream))
  (pcase-let ((`(,remote . ,merge) (oref obj variable)))
    (format-spec
     (oref obj format)
     `((?k . ,(transient-format-key obj))
       (?m . ,merge)
       (?r . ,remote)
       (?M . ,(transient-format-value obj #'cdr "refs/heads/"))
       (?R . ,(transient-format-value obj #'car))))))

(cl-defmethod transient-format-value ((obj magit--git-branch:upstream)
                                      key &optional prefix)
  (if-let ((value (oref obj value)))
      (propertize (concat prefix (funcall key value))
                  'face 'transient-argument)
    (propertize "unset" 'face 'transient-disabled-argument)))

(define-infix-argument magit-branch.<branch>.rebase ()
  :class 'magit--git-variable:choices
  :variable "branch.%s.rebase"
  :choices  '("true" "false")
  :fallback "pull.rebase"
  :default  "false")

(define-infix-argument magit-branch.<branch>.pushRemote ()
  :class 'magit--git-variable:choices
  :variable "branch.%s.pushRemote"
  :choices  'magit-list-remotes
  :fallback "remote.pushDefault")

(define-infix-argument magit-pull.rebase ()
  :class 'magit--git-variable:choices
  :variable "pull.rebase"
  :choices  '("true" "false")
  :default  "false")

(define-infix-argument magit-remote.pushDefault ()
  :class 'magit--git-variable:choices
  :variable "remote.pushDefault"
  :choices  'magit-list-remotes)

(define-infix-argument magit-branch.autoSetupMerge ()
  :class 'magit--git-variable:choices
  :variable "branch.autoSetupMerge"
  :choices  '("always" "true" "false")
  :default  "true")

(define-infix-argument magit-branch.autoSetupRebase ()
  :class 'magit--git-variable:choices
  :variable "branch.autoSetupRebase"
  :choices  '("always" "local" "remote" "never")
  :default  "never")

;;; _
(provide 'magit-branch)
;;; magit-branch.el ends here
