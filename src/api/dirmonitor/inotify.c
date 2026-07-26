#include <SDL3/SDL.h>
#include <sys/inotify.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>

#include "dirmonitor.h"

struct dirmonitor_internal {
  int fd;
  // a pipe is used to wake the thread in case of exit
  int sig[2];
};


static struct dirmonitor_internal* init_dirmonitor(void) {
  struct dirmonitor_internal* monitor = SDL_calloc(1, sizeof(struct dirmonitor_internal));
  if (!monitor)
    return NULL;
  monitor->fd = -1;
  monitor->sig[0] = -1;
  monitor->sig[1] = -1;
  monitor->fd = inotify_init();
  if (monitor->fd < 0 || pipe(monitor->sig) != 0) {
    if (monitor->fd >= 0) {
      close(monitor->fd);
      monitor->fd = -1;
    }
    return monitor;
  }
  fcntl(monitor->sig[0], F_SETFD, FD_CLOEXEC);
  fcntl(monitor->sig[1], F_SETFD, FD_CLOEXEC);
  return monitor;
}


static void deinit_dirmonitor(struct dirmonitor_internal* monitor) {
  if (!monitor)
    return;
  if (monitor->fd >= 0)
    close(monitor->fd);
  if (monitor->sig[0] >= 0)
    close(monitor->sig[0]);
  if (monitor->sig[1] >= 0)
    close(monitor->sig[1]);
}


static void wake_dirmonitor(struct dirmonitor_internal* monitor) {
  if (monitor && monitor->sig[1] >= 0) {
    ssize_t written = write(monitor->sig[1], "", 1);
    (void)written;
  }
}


static int get_changes_dirmonitor(struct dirmonitor_internal* monitor, char* buffer, int length) {
  if (!monitor || monitor->fd < 0 || monitor->sig[0] < 0)
    return -1;
  struct pollfd fds[2] = { { .fd = monitor->fd, .events = POLLIN | POLLERR, .revents = 0 }, { .fd = monitor->sig[0], .events = POLLIN | POLLERR, .revents = 0 } };
  if (poll(fds, 2, -1) <= 0)
    return -1;
  if (fds[1].revents & (POLLIN | POLLERR | POLLHUP)) {
    char signal;
    if (read(monitor->sig[0], &signal, 1) != 1)
      return -1;
    return 0;
  }
  if (!(fds[0].revents & (POLLIN | POLLERR)))
    return 0;
  return read(monitor->fd, buffer, length);
}


static int translate_changes_dirmonitor(struct dirmonitor_internal* monitor, char* buffer, int length, int (*change_callback)(int, const char*, void*), void* data) {
  for (struct inotify_event* info = (struct inotify_event*)buffer; (char*)info < buffer + length; info = (struct inotify_event*)((char*)info + sizeof(struct inotify_event) + info->len))
    change_callback(info->wd, NULL, data);
  return 0;
}


static int add_dirmonitor(struct dirmonitor_internal* monitor, const char* path) {
  if (!monitor || monitor->fd < 0)
    return -1;
  return inotify_add_watch(
    monitor->fd,
    path,
    IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO
      | IN_MODIFY | IN_CLOSE_WRITE | IN_ATTRIB
      | IN_DELETE_SELF | IN_MOVE_SELF | IN_IGNORED
  );
}


static void remove_dirmonitor(struct dirmonitor_internal* monitor, int fd) {
  if (monitor && monitor->fd >= 0 && fd >= 0)
    inotify_rm_watch(monitor->fd, fd);
}


static int get_mode_dirmonitor(void) { return 2; }

struct dirmonitor_backend dirmonitor_inotify = {
  .name = "inotify",
  .init = init_dirmonitor,
  .wake = wake_dirmonitor,
  .deinit = deinit_dirmonitor,
  .get_changes = get_changes_dirmonitor,
  .translate_changes = translate_changes_dirmonitor,
  .add = add_dirmonitor,
  .remove = remove_dirmonitor,
  .get_mode = get_mode_dirmonitor,
};
