// One stream per page: separate streams exhaust browser HTTP/1 connection slots.
export const avatarEvents=new EventSource('/events');
window.addEventListener('pagehide',()=>avatarEvents.close());
