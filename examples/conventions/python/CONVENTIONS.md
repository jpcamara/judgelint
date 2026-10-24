---
paths: ["src/**/*.py"]
---
# Python conventions

- **Network calls have a timeout.** Every HTTP request, socket, or client call
  that can hang passes an explicit timeout.

  Bad:

  ```python
  def fetch_rates():
      return requests.get(RATES_URL).json()
  ```

  Good:

  ```python
  def fetch_rates():
      return requests.get(RATES_URL, timeout=5).json()
  ```

- **Log, don't print.** Code under `src/` reports through the `logging`
  module. `print` is for scripts.

  Bad:

  ```python
  def import_rows(rows):
      for row in rows:
          if not row.get("email"):
              print("skipping row without email", row)
              continue
          save(row)
  ```

  Good:

  ```python
  logger = logging.getLogger(__name__)

  def import_rows(rows):
      for row in rows:
          if not row.get("email"):
              logger.info("skipping row without email: %s", row.get("id"))
              continue
          save(row)
  ```

- **Public functions say what they raise.** A public function's docstring
  names the exceptions a caller should handle.

  Bad:

  ```python
  def load_config(path):
      """Load the config file."""
      with open(path) as f:
          return yaml.safe_load(f)
  ```

  Good:

  ```python
  def load_config(path):
      """Load the config file.

      Raises FileNotFoundError if path doesn't exist, and yaml.YAMLError if
      the file isn't valid YAML.
      """
      with open(path) as f:
          return yaml.safe_load(f)
  ```
