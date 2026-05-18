import Config

config :junit_formatter,
  report_dir: "_build/test/junit",
  report_file: "junit.xml",
  print_report_file: true,
  prepend_project_name?: true
