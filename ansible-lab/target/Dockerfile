FROM docker.m.daocloud.io/library/ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
	openssh-server python3 sudo \
 && rm -rf /var/lib/apt/lists/*

RUN echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible \
 && chmod 0440 /etc/sudoers.d/ansible

RUN useradd -m -s /bin/bash ansible \
	&& mkdir -p /home/ansible/.ssh \
	&& chmod 700 /home/ansible/.ssh \
	&& usermod -aG sudo ansible

COPY id_ed25519.pub /home/ansible/.ssh/authorized_keys
RUN chown -R ansible:ansible /home/ansible/.ssh \
 && chmod 600 /home/ansible/.ssh/authorized_keys

RUN mkdir -p /run/sshd
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D","-e"]
