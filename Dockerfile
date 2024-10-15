# Use Ubuntu as the base image
FROM ubuntu:20.04

# Set the environment variable for non-interactive apt install
ENV DEBIAN_FRONTEND=noninteractive

# Update and install necessary packages
RUN apt-get update && \
    apt-get install -y software-properties-common curl python3-pip python3-apt sshpass && \
    apt-get clean

# Ensure python3 is the default for python command
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3 1

# Install Ansible and necessary dependencies via pip3
RUN pip3 install --upgrade pip
RUN pip3 install ansible

# Set the working directory
WORKDIR /ansible

# Copy your playbooks and roles into the Docker container
COPY . /ansible

# Set the default command to ensure the container stays alive
CMD [ "tail", "-f", "/dev/null" ]
