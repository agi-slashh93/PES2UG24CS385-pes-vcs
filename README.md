# PES-VCS Lab Report

## Implementation Overview

PES-VCS is a local version control system built from scratch in C, modelled after Git's internal design. It implements content-addressable object storage, tree hierarchy construction, a text-based staging area, and commit history with parent-pointer linked lists.

---

## Phase 1 — Object Storage

### What Was Implemented

**`object_write`** builds a full object by prepending a header (`"<type> <size>\0"`) to the raw data, computes a SHA-256 hash of the whole thing, deduplicates by checking existence, shards into `.pes/objects/XX/`, writes atomically via a temp file + `fsync` + `rename`, and syncs the shard directory.

**`object_read`** reconstructs the file path from the hash, reads the file, recomputes SHA-256 to verify integrity (returns `-1` on mismatch), parses the header to extract type and size, and returns a heap-allocated copy of the data portion.



## Phase 2 — Tree Objects

### What Was Implemented

**`tree_from_index`** loads the index and calls a recursive helper `write_tree_level(entries, count, prefix, id_out)`. The helper iterates index entries that share a given path prefix. If an entry has no `/` after the prefix it is a direct file and becomes a blob `TreeEntry`. If it has a `/`, the subdirectory name is extracted, a new prefix is formed, and the helper recurses. After processing all entries at a level, `tree_serialize` and `object_write(OBJ_TREE, ...)` persist the tree, and the hash is returned up the call stack.



## Phase 3 — Index (Staging Area)

### What Was Implemented

**`index_load`** opens `.pes/index` for reading (returns an empty index if the file doesn't exist). Each line is parsed with `sscanf` using the format `"%o %64s %llu %u %511s"` to extract mode, hex hash, mtime, size, and path. `hex_to_hash` converts the hex string to an `ObjectID`.

**`index_save`** heap-allocates a copy of the index (to avoid stack overflow with 10,000-entry structs), sorts by path with `qsort`, writes to a temp file via `fprintf`, calls `fflush`/`fsync`/`fclose`, then `rename`s atomically over the real index file.

**`index_add`** reads the file contents with `fopen`/`fread`, writes them as a blob via `object_write(OBJ_BLOB, ...)`, calls `lstat` for metadata, and either updates an existing index entry (found via `index_find`) or appends a new one, then calls `index_save`.



## Phase 4 — Commits and History

### What Was Implemented

**`commit_create`** calls `tree_from_index` to get the root tree hash, attempts `head_read` to get the parent commit (skipped for the first commit by checking the return value), fills a `Commit` struct with the tree hash, parent, author string from `pes_author()`, and `time(NULL)` timestamp, serializes it with `commit_serialize`, writes it with `object_write(OBJ_COMMIT, ...)`, and finally calls `head_update` to atomically advance the branch pointer.


## Phase 5 — Branching and Checkout (Analysis)

### Q5.1 — How would you implement `pes checkout <branch>`?

`pes checkout <branch>` needs to do two things: update the repository metadata and update the working directory.

**Repository metadata changes in `.pes/`:**
- Rewrite `HEAD` to contain `ref: refs/heads/<branch>` (or create the branch file first if switching to a new branch). This is a single atomic write using the temp-file-then-rename pattern.

**Working directory update:**
1. Read the target branch's commit hash from `.pes/refs/heads/<branch>`.
2. Parse that commit object to get its root tree hash.
3. Walk the tree recursively: for every blob entry, read the blob from the object store and overwrite the corresponding working file with its contents. For subtrees, create directories as needed.
4. Files that exist in the current tree but not in the target tree must be deleted.
5. Update the index to match the target tree exactly (each entry's hash, mtime, size).

**What makes it complex:**

The hard part is handling files the user has modified but not staged. You need to detect these "dirty" files and refuse to overwrite them (otherwise the user loses work). This requires a three-way comparison per file: current working file vs index entry vs target tree entry. If the working file differs from the index (user has local edits) AND the target tree has a different version of the same file, the checkout must abort with an error like `"error: Your local changes to 'foo.c' would be overwritten by checkout"`. Handling new files that only exist in one branch, and correctly managing directory creation and deletion, adds further edge cases.

### Q5.2 — Detecting dirty working directory conflicts

For each file that appears in **both** the current branch's tree and the target branch's tree but with **different blob hashes**:

1. Look up the file's entry in the index (using `index_find`).
2. Call `stat()` on the working file and compare `st_mtime` and `st_size` against the stored `mtime_sec` and `size` in the index entry.
3. If either differs, the file has been modified since it was last staged — it is "dirty."
4. A dirty file whose blob hash differs between the two branches is a conflict: checkout must refuse.

For absolute certainty (since mtime can be unreliable in some scenarios), you can re-hash the working file with `object_write` or `compute_hash` and compare directly against the index's stored `ObjectID`. This is slower but eliminates false negatives from timestamp collisions.

Files that only exist in one branch and are also present in the working directory (but untracked) should also be checked: if the target branch would create a file at a path that already exists as an untracked working file, checkout should refuse to overwrite it.

### Q5.3 — Detached HEAD and Recovery

In detached HEAD state, `HEAD` contains a raw commit hash (`abc123...`) instead of a branch reference (`ref: refs/heads/main`). When you make new commits, `head_update` writes the new commit hash directly into `HEAD`. No branch file is ever updated, so the new commits have no named reference pointing to them.

If you then run `pes checkout main`, `HEAD` is rewritten to `ref: refs/heads/main`, and the detached commits are now **unreachable** — no branch, tag, or HEAD points to them. They will be collected by garbage collection eventually.

**Recovery:** If you still have the commit hash (from terminal scrollback, or from `pes log` output taken before switching), you can recover by creating a new branch pointing to it:

```bash
echo "<lost-commit-hash>" > .pes/refs/heads/recovery
```

Then checkout that branch. This is exactly what Git's `git branch recovery <hash>` does. Without the hash, recovery is only possible if GC hasn't run yet — you could scan all objects in `.pes/objects/` looking for commit objects, parse them, and reconstruct the dangling chain.

---

## Phase 6 — Garbage Collection (Analysis)

### Q6.1 — Algorithm to Find and Delete Unreachable Objects

**Algorithm (mark-and-sweep):**

1. **Mark phase** — collect all reachable object hashes into a hash set:
   - Start from every file in `.pes/refs/heads/` (each is a commit hash).
   - For each commit: mark it reachable, parse it to get its tree hash and parent hash.
   - Recursively walk the tree: mark the tree object, then for each entry, if it is a blob mark it, if it is a subtree recurse into it.
   - Follow the parent pointer and repeat until a commit with no parent is reached.
   - Repeat for all branches.

2. **Sweep phase** — delete unmarked objects:
   - `find .pes/objects -type f` to enumerate all stored objects.
   - Convert each filename (shard dir + filename) back to a 64-char hex hash.
   - If the hash is not in the reachable set, delete the file.
   - Remove any now-empty shard directories.

**Data structure:** A hash set of `ObjectID` values (32-byte binary hashes). In C, a sorted array of hashes with `bsearch` works well and requires only `32 × N` bytes. For large repos, a proper hash table gives O(1) lookup instead of O(log N).

**Estimate for 100,000 commits, 50 branches:**
Assuming an average of 10 unique files per commit (many files are shared across commits via deduplication), and one tree object per commit:
- Commits: ~100,000
- Tree objects: ~100,000 (root trees) + subtrees ≈ ~200,000
- Blob objects: 10 unique blobs/commit × 100,000 ≈ ~1,000,000 (with deduplication, much fewer in practice)

In the worst case (no sharing), you visit roughly **1.2 million objects**. With typical deduplication, the reachable set is much smaller — perhaps 50,000–200,000 unique blobs.

### Q6.2 — GC Race Condition with Concurrent Commits

**The race condition:**

1. A `commit` operation calls `object_write` to store a new **blob** (the contents of a staged file). The blob is now on disk in `.pes/objects/`.
2. GC runs at this exact moment. It traverses all branches and their commit chains. The new blob has not yet been referenced by any tree or commit object, so GC marks it **unreachable** and deletes it.
3. The `commit` operation continues: it calls `tree_from_index`, which calls `object_write(OBJ_TREE, ...)` referencing the blob's hash. It then calls `object_write(OBJ_COMMIT, ...)`. The commit object is written and `head_update` is called — but the blob the tree points to no longer exists. The repository is now **corrupt**.

**How Git avoids this:**

Git's real GC (`git gc`) uses a **grace period**: any object whose file modification time is newer than a configurable threshold (default: 2 weeks for loose objects) is treated as reachable regardless of whether any reference points to it. An in-progress `git commit` takes milliseconds, not weeks, so its intermediate objects are always protected.

Additionally, Git writes a `.git/gc.pid` lockfile before starting GC, preventing two GC processes from running concurrently. The lock is checked and any existing lock from a live PID causes GC to abort. Git also writes `FETCH_HEAD`, `MERGE_HEAD`, and other temporary refs that keep intermediate objects reachable during multi-step operations.

In PES-VCS, the simplest safe approach would be: before GC deletes any object, check `st_mtime` — skip deletion if the object is younger than a grace period (e.g., 60 seconds). A more robust approach would use an advisory lock file (`.pes/GC_LOCK`) that `commit_create` holds for its duration, and GC refuses to run while the lock exists.
