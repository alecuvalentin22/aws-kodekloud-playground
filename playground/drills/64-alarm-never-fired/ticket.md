From: Mara (on-call, payments)                                #help-platform

  checkout threw errors for 20 minutes about two hours ago (customers noticed
  before we did) and NOTHING paged. the alarm is right there,
  platform-lab-drill64-checkout-errors in CloudWatch (us-east-1), and it says OK.
  the Errors graph for checkout clearly spikes. so why didn't it fire?
  metrics live in the platform-lab/drill64 namespace.
  I'm on call again tonight. can you make sure it WILL fire next time, and
  show me it does? (creds: set -a; . ~/.config/platform-lab/aws-lab-creds.env; set +a)

From: Tom (wrote the alarm)                                   #help-platform

  I copied the alarm from the old Datadog monitor. 5 errors in a minute, treat
  missing data as fine because checkout only reports Errors when there are some.
  looked right to me.
