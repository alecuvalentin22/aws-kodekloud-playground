From: Priya (payments team)                                   #help-platform

  we moved off the golden path last week (API contract check + a small pod
  for Deploy, so we don't hold BuildKit's memory while kubectl waits). today
  main went red at Deploy:

    java.nio.file.NoSuchFileException: .../workspace/demo-api_main/image-ref.txt

  but the file is RIGHT THERE: the Build image stage wrote it and echoed the
  image. I re-ran twice, same thing. did Jenkins lose it? nothing has been
  deployed since.
