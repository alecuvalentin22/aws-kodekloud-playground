# Drill 17 — 1.9 GB free and still dying: burst credits and steal time

**The question:** "How do you tell whether a box is too small?"

By looking at the *right* resource. Two nodes failed in one afternoon, both
`t3.medium`, both looking like "not enough RAM". Only one of them was.

## Node A — genuinely out of memory

k3s-01 stopped answering SSH mid-rollout. TCP connected; the handshake never
completed. EC2 status checks stayed **green** the whole time, because the
hypervisor was fine — only the guest was starved.

Cause: a `replicas: 1` Deployment with the default `RollingUpdate` gets
`maxSurge: 1`, so two Keycloaks ran at once (~2 GiB) alongside k3s, Kong,
cert-manager and Rancher on 4 GiB — with **swap disabled** by the `common` role
(correct, for Elasticsearch). Nothing degrades gracefully without swap; it
wedges. Only an EC2 reboot recovered it, and the soft reboot took ~4 minutes to
bite because a wedged kernel ignores ACPI.

Fix: `strategy: Recreate`, and feature toggles to shed load. See drills/15.

## Node B — plenty of memory, no CPU

rke2-01 could not get Rancher to start. Rancher's pod ran, failed its startup
probe, was killed, restarted — three times. The obvious guess was memory.

```
$ free -m
Mem:  total 3834   used 1940   available 1893      <- 1.9 GB FREE
```

Memory was fine. The actual cause:

```
$ top -bn1 | grep %Cpu
%Cpu(s): 14.3 us,  3.6 sy,  0.0 id,  0.0 wa,  82.1 st
                                                 ^^^^^^
```

**82.1% steal.** `st` is time the hypervisor took back — cycles this vCPU
wanted and did not get. The box has ~18% of the CPU it appears to have.

## Why: T-instances are a credit system, not a CPU

`t2`/`t3`/`t4g` are **burstable**. Each instance earns CPU credits per hour and
spends them to exceed a **baseline**:

| | t3.medium |
|---|---|
| vCPUs | 2 |
| baseline | **20%** of 2 vCPUs |
| credits earned | 24 / hour |
| launch credits | 30 (one-time) |

Run above baseline and you spend credits. Run out, and behaviour depends on the
mode:

- **`unlimited`** (the AWS default for t3) — keeps bursting and **bills you** for
  surplus credits
- **`standard`** — hard-throttles to baseline

This lab is forced into `standard`:

```hcl
credit_specification {
  cpu_credits = "standard"   # unlimited mode SUSPENDS the KodeKloud session
}
```

So installing RKE2 — pulling images, starting a static-pod control plane, canal,
coredns, metrics-server — burned the 30 launch credits in about 20 minutes.
After that: throttled to 20%, 82% steal, and everything takes five times longer.

## The spiral

Rancher's startup probe allowed `failureThreshold: 12 × periodSeconds: 10` =
**120 seconds**. Rancher cannot start in 120s at 18% CPU. So the kubelet killed
it — and a container restart is *more* CPU work, which spends *more* credit,
which makes the next attempt slower. Exactly the shape of the Kong liveness
failure in drills/15, different resource.

Widening the budget to 900s broke the spiral:

```
12:08:41  0/1   84.8 st
12:09:19  0/1   78.1 st
12:10:35  0/1   81.2 st
12:11:16  1/1   70.3 st     <- Ready
```

Nothing was wrong with Rancher. It needed nine minutes of wall-clock because it
was only getting a fifth of a CPU.

## How to tell these apart in 10 seconds

```bash
free -m                      # available column -> memory pressure?
top -bn1 | grep '%Cpu'       # st -> hypervisor throttling
uptime                       # load >> vCPUs with low %us -> waiting, not working
```

And from outside, on a T-instance, the number that actually matters:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/EC2 \
  --metric-name CPUCreditBalance --dimensions Name=InstanceId,Value=i-... \
  --start-time ... --end-time ... --period 300 --statistics Average
```

`CPUCreditBalance` hitting zero is the alarm nobody sets, and it is the single
best predictor of "the app got mysteriously slow on Tuesday afternoon".

## The rule

**Steal time cannot be fixed from inside the instance.** No amount of tuning,
toggling or right-sizing pods reclaims cycles the hypervisor is not giving you.
The only fixes are external: change instance type, change family to a
non-burstable one (`m`/`c`), or switch to `unlimited` and accept the bill.

Burstable instances are correct for spiky, mostly-idle workloads — a bastion, a
CI runner, a dev box. They are wrong for anything with a **sustained** floor:
Elasticsearch, a Kubernetes control plane, or a JVM app server. This lab runs
both kinds on `t3.medium`, which is why it works right up until it doesn't.

## Say this in the interview

> "Rancher kept failing its startup probe and I assumed memory — but `free`
> showed 1.9 GB available. The giveaway was `top`: 82% steal. It's a t3.medium
> in `standard` credit mode, and installing RKE2 had burned the launch credits,
> so it was throttled to its 20% baseline.
>
> That turned into a spiral, because the startup probe only allowed 120 seconds
> and each restart burned more credit. Widening the probe let it come up in nine
> minutes.
>
> The general lesson is that steal time is invisible to everything inside the
> box and can't be fixed from inside it. And burstable instances are the wrong
> family for anything with a sustained CPU floor — which a Kubernetes control
> plane absolutely is. I'd alarm on `CPUCreditBalance`, because by the time
> users complain, you're already at baseline."
