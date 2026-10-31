import { Navigate, type RouteObject } from 'react-router'
import { RequiereSesion, SoloAnonimo } from '@/auth/Guardas'
import { PaginaEntrar } from '@/features/auth/PaginaEntrar'
import { PaginaRegistro } from '@/features/auth/PaginaRegistro'
import { VistaConversacion } from '@/features/chat/VistaConversacion'
import { PaginaContactos } from '@/features/contactos/PaginaContactos'
import { DisenoChats, SinConversacion } from '@/features/conversaciones/DisenoChats'
import { PaginaPerfil } from '@/features/perfil/PaginaPerfil'
import { AppShell } from '@/layout/AppShell'
import { NoEncontrada } from '@/layout/NoEncontrada'

export const rutas: RouteObject[] = [
  { index: true, element: <Navigate to="/chats" replace /> },
  {
    element: <SoloAnonimo />,
    children: [
      { path: 'entrar', element: <PaginaEntrar /> },
      { path: 'registro', element: <PaginaRegistro /> },
    ],
  },
  {
    element: <RequiereSesion />,
    children: [
      {
        element: <AppShell />,
        children: [
          {
            path: 'chats',
            element: <DisenoChats />,
            children: [
              { index: true, element: <SinConversacion /> },
              { path: ':conversacionId', element: <VistaConversacion /> },
            ],
          },
          { path: 'contactos', element: <PaginaContactos /> },
          { path: 'perfil', element: <PaginaPerfil /> },
        ],
      },
    ],
  },
  { path: '*', element: <NoEncontrada /> },
]
